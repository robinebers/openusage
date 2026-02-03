(function () {
  const AUTH_PATH = "~/.codex/auth.json"
  const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
  const REFRESH_URL = "https://auth.openai.com/oauth/token"
  const USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
  const REFRESH_AGE_MS = 8 * 24 * 60 * 60 * 1000

  function loadAuth(ctx) {
    if (!ctx.host.fs.exists(AUTH_PATH)) return null
    try {
      const text = ctx.host.fs.readText(AUTH_PATH)
      return ctx.util.tryParseJson(text)
    } catch {
      return null
    }
  }

  function needsRefresh(ctx, auth, nowMs) {
    if (!auth.last_refresh) return true
    const lastMs = ctx.util.parseDateMs(auth.last_refresh)
    if (lastMs === null) return true
    return nowMs - lastMs > REFRESH_AGE_MS
  }

  function refreshToken(ctx, auth) {
    if (!auth.tokens || !auth.tokens.refresh_token) return null

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
      if (resp.status < 200 || resp.status >= 300) return null

      const body = ctx.util.tryParseJson(resp.bodyText)
      if (!body) return null
      const newAccessToken = body.access_token
      if (!newAccessToken) return null

      auth.tokens.access_token = newAccessToken
      if (body.refresh_token) auth.tokens.refresh_token = body.refresh_token
      if (body.id_token) auth.tokens.id_token = body.id_token
      auth.last_refresh = new Date().toISOString()

      try {
        ctx.host.fs.writeText(AUTH_PATH, JSON.stringify(auth, null, 2))
      } catch {}

      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
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

  function getResetIn(ctx, nowSec, window) {
    if (!window) return null
    if (typeof window.reset_at === "number") {
      return ctx.fmt.resetIn(window.reset_at - nowSec)
    }
    if (typeof window.reset_after_seconds === "number") {
      return ctx.fmt.resetIn(window.reset_after_seconds)
    }
    return null
  }

  function probe(ctx) {
    const auth = loadAuth(ctx)
    if (!auth) {
      throw "Not logged in. Run `codex` to authenticate."
    }

    if (auth.tokens && auth.tokens.access_token) {
      const nowMs = Date.now()
      let accessToken = auth.tokens.access_token
      const accountId = auth.tokens.account_id

      if (needsRefresh(ctx, auth, nowMs)) {
        const refreshed = refreshToken(ctx, auth)
        if (refreshed) accessToken = refreshed
      }

      let resp
      let didRefresh = false
      try {
        resp = ctx.util.retryOnceOnAuth({
          request: (token) => {
            try {
              return fetchUsage(ctx, token || accessToken, accountId)
            } catch {
              if (didRefresh) {
                throw "Usage request failed after refresh. Try again."
              }
              throw "Usage request failed. Check your connection."
            }
          },
          refresh: () => {
            didRefresh = true
            return refreshToken(ctx, auth)
          },
        })
      } catch (e) {
        if (typeof e === "string") throw e
        throw "Usage request failed. Check your connection."
      }

      if (ctx.util.isAuthStatus(resp.status)) {
        throw "Token expired. Run `codex` to log in again."
      }

      if (resp.status < 200 || resp.status >= 300) {
        throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
      }

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
        const resetIn = getResetIn(ctx, nowSec, primaryWindow)
        lines.push(ctx.line.progress({
          label: "Session",
          value: headerPrimary,
          max: 100,
          unit: "percent",
          subtitle: resetIn ? "Resets in " + resetIn : null
        }))
      }
      if (headerSecondary !== null) {
        const resetIn = getResetIn(ctx, nowSec, secondaryWindow)
        lines.push(ctx.line.progress({
          label: "Weekly",
          value: headerSecondary,
          max: 100,
          unit: "percent",
          subtitle: resetIn ? "Resets in " + resetIn : null
        }))
      }

      if (lines.length === 0 && data.rate_limit) {
        if (data.rate_limit.primary_window && typeof data.rate_limit.primary_window.used_percent === "number") {
          const resetIn = getResetIn(ctx, nowSec, primaryWindow)
          lines.push(ctx.line.progress({
            label: "Session",
            value: data.rate_limit.primary_window.used_percent,
            max: 100,
            unit: "percent",
            subtitle: resetIn ? "Resets in " + resetIn : null
          }))
        }
        if (data.rate_limit.secondary_window && typeof data.rate_limit.secondary_window.used_percent === "number") {
          const resetIn = getResetIn(ctx, nowSec, secondaryWindow)
          lines.push(ctx.line.progress({
            label: "Weekly",
            value: data.rate_limit.secondary_window.used_percent,
            max: 100,
            unit: "percent",
            subtitle: resetIn ? "Resets in " + resetIn : null
          }))
        }
      }

      if (reviewWindow) {
        const used = reviewWindow.used_percent
        if (typeof used === "number") {
          const resetIn = getResetIn(ctx, nowSec, reviewWindow)
          lines.push(ctx.line.progress({
            label: "Reviews",
            value: used,
            max: 100,
            unit: "percent",
            subtitle: resetIn ? "Resets in " + resetIn : null
          }))
        }
      }

      const creditsBalance = resp.headers["x-codex-credits-balance"]
      const creditsHeader = readNumber(creditsBalance)
      const creditsData = data.credits ? readNumber(data.credits.balance) : null
      if (creditsHeader !== null) {
        lines.push(ctx.line.progress({ label: "Credits", value: creditsHeader, max: 1000 }))
      } else if (creditsData !== null) {
        lines.push(ctx.line.progress({ label: "Credits", value: creditsData, max: 1000 }))
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
