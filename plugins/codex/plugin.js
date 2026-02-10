(function () {
  const AUTH_FILE = "auth.json"
  const CONFIG_AUTH_PATHS = ["~/.config/codex", "~/.codex"]
  const KEYCHAIN_SERVICE = "Codex Auth"
  const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
  const REFRESH_URL = "https://auth.openai.com/oauth/token"
  const USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
  const REFRESH_AGE_MS = 8 * 24 * 60 * 60 * 1000

  function joinPath(base, leaf) {
    return base.replace(/[\\/]+$/, "") + "/" + leaf
  }

  function readCodexHome(ctx) {
    if (!ctx.host.env || typeof ctx.host.env.get !== "function") {
      return null
    }

    try {
      const value = ctx.host.env.get("CODEX_HOME")
      if (typeof value !== "string") return null
      const trimmed = value.trim()
      return trimmed || null
    } catch (e) {
      ctx.host.log.warn("CODEX_HOME read failed: " + String(e))
      return null
    }
  }

  function decodeHexUtf8(hex) {
    try {
      const bytes = []
      for (let i = 0; i < hex.length; i += 2) {
        bytes.push(parseInt(hex.slice(i, i + 2), 16))
      }

      if (typeof TextDecoder !== "undefined") {
        try {
          return new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(bytes))
        } catch {}
      }

      let escaped = ""
      for (const b of bytes) {
        const h = b.toString(16)
        escaped += "%" + (h.length === 1 ? "0" + h : h)
      }
      return decodeURIComponent(escaped)
    } catch {
      return null
    }
  }

  function tryParseAuthJson(ctx, text) {
    if (!text) return null
    const parsed = ctx.util.tryParseJson(text)
    if (parsed) return parsed

    // Some keychain payloads can be returned as hex-encoded UTF-8 bytes.
    let hex = String(text).trim()
    if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.slice(2)
    if (!hex || hex.length % 2 !== 0) return null
    if (!/^[0-9a-fA-F]+$/.test(hex)) return null

    const decoded = decodeHexUtf8(hex)
    if (!decoded) return null
    return ctx.util.tryParseJson(decoded)
  }

  function resolveAuthPaths(ctx) {
    const codexHome = readCodexHome(ctx)

    // If CODEX_HOME is set, use it
    if (codexHome) {
      return [joinPath(codexHome, AUTH_FILE)]
    }

    return CONFIG_AUTH_PATHS.map((basePath) => joinPath(basePath, AUTH_FILE))
  }

  function hasTokenLikeAuth(auth) {
    if (!auth || typeof auth !== "object") return false
    if (auth.tokens && auth.tokens.access_token) return true
    if (auth.OPENAI_API_KEY) return true
    return false
  }

  function loadAuthFromKeychain(ctx) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readGenericPassword !== "function") {
      return null
    }

    try {
      const value = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE)
      if (!value) return null
      const auth = tryParseAuthJson(ctx, value)
      if (!hasTokenLikeAuth(auth)) {
        ctx.host.log.warn("keychain has data but no codex auth payload")
        return null
      }
      ctx.host.log.info("auth loaded from keychain: " + KEYCHAIN_SERVICE)
      return { auth, authPath: null, source: "keychain" }
    } catch (e) {
      ctx.host.log.info("keychain read failed (may not exist): " + String(e))
      return null
    }
  }

  function saveAuth(ctx, authState) {
    const auth = authState && authState.auth ? authState.auth : null
    if (!auth) return false

    if (authState.source === "file" && authState.authPath) {
      ctx.host.fs.writeText(authState.authPath, JSON.stringify(auth, null, 2))
      return true
    }

    if (authState.source === "keychain") {
      if (!ctx.host.keychain || typeof ctx.host.keychain.writeGenericPassword !== "function") {
        ctx.host.log.warn("keychain write unsupported in this host")
        return false
      }
      // Use compact JSON to avoid newline-induced keychain encoding issues.
      ctx.host.keychain.writeGenericPassword(KEYCHAIN_SERVICE, JSON.stringify(auth))
      return true
    }

    return false
  }

  function loadAuth(ctx) {
    const authPaths = resolveAuthPaths(ctx)
    for (const authPath of authPaths) {
      if (!ctx.host.fs.exists(authPath)) continue
      try {
        const text = ctx.host.fs.readText(authPath)
        const auth = tryParseAuthJson(ctx, text)
        if (!hasTokenLikeAuth(auth)) {
          ctx.host.log.warn("auth file exists but no valid codex auth payload: " + authPath)
          continue
        }
        ctx.host.log.info("auth loaded from file: " + authPath)
        return { auth, authPath, source: "file" }
      } catch (e) {
        ctx.host.log.warn("auth file read failed: " + String(e))
      }
    }

    const keychainAuth = loadAuthFromKeychain(ctx)
    if (keychainAuth) return keychainAuth

    if (authPaths.length > 0) {
      for (const authPath of authPaths) {
        if (!ctx.host.fs.exists(authPath)) {
          ctx.host.log.warn("auth file not found: " + authPath)
        }
      }
    }

    return null
  }

  function needsRefresh(ctx, auth, nowMs) {
    if (!auth.last_refresh) return true
    const lastMs = ctx.util.parseDateMs(auth.last_refresh)
    if (lastMs === null) return true
    return nowMs - lastMs > REFRESH_AGE_MS
  }

  function refreshToken(ctx, authState) {
    const auth = authState.auth
    if (!auth.tokens || !auth.tokens.refresh_token) {
      ctx.host.log.warn("refresh skipped: no refresh token")
      return null
    }

    ctx.host.log.info("attempting token refresh")
    try {
      const resp = ctx.util.request({
        method: "POST",
        url: REFRESH_URL,
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        bodyText:
          "grant_type=refresh_token" +
          "&client_id=" + encodeURIComponent(CLIENT_ID) +
          "&refresh_token=" + encodeURIComponent(auth.tokens.refresh_token),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        let code = null
        const body = ctx.util.tryParseJson(resp.bodyText)
        if (body) {
          code = body.error?.code || body.error || body.code
        }
        ctx.host.log.error("refresh failed: status=" + resp.status + " code=" + String(code))
        if (code === "refresh_token_expired") {
          throw "Session expired. Run `codex` to log in again."
        }
        if (code === "refresh_token_reused") {
          throw "Token conflict. Run `codex` to log in again."
        }
        if (code === "refresh_token_invalidated") {
          throw "Token revoked. Run `codex` to log in again."
        }
        throw "Token expired. Run `codex` to log in again."
      }
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("refresh returned unexpected status: " + resp.status)
        return null
      }

      const body = ctx.util.tryParseJson(resp.bodyText)
      if (!body) {
        ctx.host.log.warn("refresh response not valid JSON")
        return null
      }
      const newAccessToken = body.access_token
      if (!newAccessToken) {
        ctx.host.log.warn("refresh response missing access_token")
        return null
      }

      auth.tokens.access_token = newAccessToken
      if (body.refresh_token) auth.tokens.refresh_token = body.refresh_token
      if (body.id_token) auth.tokens.id_token = body.id_token
      auth.last_refresh = new Date().toISOString()

      try {
        const saved = saveAuth(ctx, authState)
        if (saved) {
          ctx.host.log.info("refresh succeeded, auth persisted to " + authState.source)
        } else {
          ctx.host.log.warn("refresh succeeded but auth persistence was not possible")
        }
      } catch (e) {
        ctx.host.log.warn("refresh succeeded but failed to save auth: " + String(e))
      }

      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("refresh exception: " + String(e))
      return null
    }
  }

  function fetchUsage(ctx, accessToken, accountId) {
    const headers = {
      Authorization: "Bearer " + accessToken,
      Accept: "application/json",
      "User-Agent": "OpenUsage",
    }
    if (accountId) {
      headers["ChatGPT-Account-Id"] = accountId
    }
    return ctx.util.request({
      method: "GET",
      url: USAGE_URL,
      headers,
      timeoutMs: 10000,
    })
  }

  function readPercent(value) {
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function readNumber(value) {
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function getResetsAtIso(ctx, nowSec, window) {
    if (!window) return null
    if (typeof window.reset_at === "number") {
      return ctx.util.toIso(window.reset_at)
    }
    if (typeof window.reset_after_seconds === "number") {
      return ctx.util.toIso(nowSec + window.reset_after_seconds)
    }
    return null
  }

  // Period durations in milliseconds
  var PERIOD_SESSION_MS = 5 * 60 * 60 * 1000    // 5 hours
  var PERIOD_WEEKLY_MS = 7 * 24 * 60 * 60 * 1000 // 7 days

  function probe(ctx) {
    const authState = loadAuth(ctx)
    if (!authState || !authState.auth) {
      ctx.host.log.error("probe failed: not logged in")
      throw "Not logged in. Run `codex` to authenticate."
    }
    const auth = authState.auth

    if (auth.tokens && auth.tokens.access_token) {
      const nowMs = Date.now()
      let accessToken = auth.tokens.access_token
      const accountId = auth.tokens.account_id

      if (needsRefresh(ctx, auth, nowMs)) {
        ctx.host.log.info("token needs refresh (age > " + (REFRESH_AGE_MS / 1000 / 60 / 60 / 24) + " days)")
        const refreshed = refreshToken(ctx, authState)
        if (refreshed) {
          accessToken = refreshed
        } else {
          ctx.host.log.warn("proactive refresh failed, trying with existing token")
        }
      }

      let resp
      let didRefresh = false
      try {
        resp = ctx.util.retryOnceOnAuth({
          request: (token) => {
            try {
              return fetchUsage(ctx, token || accessToken, accountId)
            } catch (e) {
              ctx.host.log.error("usage request exception: " + String(e))
              if (didRefresh) {
                throw "Usage request failed after refresh. Try again."
              }
              throw "Usage request failed. Check your connection."
            }
          },
          refresh: () => {
            ctx.host.log.info("usage returned 401, attempting refresh")
            didRefresh = true
            return refreshToken(ctx, authState)
          },
        })
      } catch (e) {
        if (typeof e === "string") throw e
        ctx.host.log.error("usage request failed: " + String(e))
        throw "Usage request failed. Check your connection."
      }

      if (ctx.util.isAuthStatus(resp.status)) {
        ctx.host.log.error("usage returned auth error after all retries: status=" + resp.status)
        throw "Token expired. Run `codex` to log in again."
      }

      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.error("usage returned error: status=" + resp.status)
        throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
      }

      ctx.host.log.info("usage fetch succeeded")

      const data = ctx.util.tryParseJson(resp.bodyText)
      if (data === null) {
        throw "Usage response invalid. Try again later."
      }

      const lines = []
      const nowSec = Math.floor(Date.now() / 1000)
      const rateLimit = data.rate_limit || null
      const primaryWindow = rateLimit && rateLimit.primary_window ? rateLimit.primary_window : null
      const secondaryWindow = rateLimit && rateLimit.secondary_window ? rateLimit.secondary_window : null
      const reviewWindow =
        data.code_review_rate_limit && data.code_review_rate_limit.primary_window
          ? data.code_review_rate_limit.primary_window
          : null

      const headerPrimary = readPercent(resp.headers["x-codex-primary-used-percent"])
      const headerSecondary = readPercent(resp.headers["x-codex-secondary-used-percent"])

      if (headerPrimary !== null) {
        lines.push(ctx.line.progress({
          label: "Session",
          used: headerPrimary,
          limit: 100,
          format: { kind: "percent" },
          resetsAt: getResetsAtIso(ctx, nowSec, primaryWindow),
          periodDurationMs: PERIOD_SESSION_MS
        }))
      }
      if (headerSecondary !== null) {
        lines.push(ctx.line.progress({
          label: "Weekly",
          used: headerSecondary,
          limit: 100,
          format: { kind: "percent" },
          resetsAt: getResetsAtIso(ctx, nowSec, secondaryWindow),
          periodDurationMs: PERIOD_WEEKLY_MS
        }))
      }

      if (lines.length === 0 && data.rate_limit) {
        if (data.rate_limit.primary_window && typeof data.rate_limit.primary_window.used_percent === "number") {
          lines.push(ctx.line.progress({
            label: "Session",
            used: data.rate_limit.primary_window.used_percent,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: getResetsAtIso(ctx, nowSec, primaryWindow),
            periodDurationMs: PERIOD_SESSION_MS
          }))
        }
        if (data.rate_limit.secondary_window && typeof data.rate_limit.secondary_window.used_percent === "number") {
          lines.push(ctx.line.progress({
            label: "Weekly",
            used: data.rate_limit.secondary_window.used_percent,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: getResetsAtIso(ctx, nowSec, secondaryWindow),
            periodDurationMs: PERIOD_WEEKLY_MS
          }))
        }
      }

      if (reviewWindow) {
        const used = reviewWindow.used_percent
        if (typeof used === "number") {
          lines.push(ctx.line.progress({
            label: "Reviews",
            used: used,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: getResetsAtIso(ctx, nowSec, reviewWindow),
            periodDurationMs: PERIOD_WEEKLY_MS // code_review_rate_limit is a 7-day window
          }))
        }
      }

      const creditsBalance = resp.headers["x-codex-credits-balance"]
      const creditsHeader = readNumber(creditsBalance)
      const creditsData = data.credits ? readNumber(data.credits.balance) : null
      const creditsRemaining = creditsHeader ?? creditsData
      if (creditsRemaining !== null) {
        const remaining = creditsRemaining
        const limit = 1000
        const used = Math.max(0, Math.min(limit, limit - remaining))
        lines.push(ctx.line.progress({
          label: "Credits",
          used: used,
          limit: limit,
          format: { kind: "count", suffix: "credits" },
        }))
      }

      let plan = null
      if (data.plan_type) {
        const planLabel = ctx.fmt.planLabel(data.plan_type)
        if (planLabel) {
          plan = planLabel
        }
      }

      if (lines.length === 0) {
        lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
      }

      return { plan: plan, lines: lines }
    }

    if (auth.OPENAI_API_KEY) {
      throw "Usage not available for API key."
    }

    throw "Not logged in. Run `codex` to authenticate."
  }

  globalThis.__openusage_plugin = { id: "codex", probe }
})()
