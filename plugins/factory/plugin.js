(function () {
  const AUTH_PATH = "~/.factory/auth.json"
  const WORKOS_CLIENT_ID = "client_01HNM792M5G5G1A2THWPXKFMXB"
  const WORKOS_AUTH_URL = "https://api.workos.com/user_management/authenticate"
  const USAGE_URL = "https://api.factory.ai/api/organization/subscription/usage"
  const TOKEN_REFRESH_THRESHOLD_MS = 24 * 60 * 60 * 1000 // 24 hours before expiry

  function loadAuth(ctx) {
    if (!ctx.host.fs.exists(AUTH_PATH)) {
      ctx.host.log.warn("auth file not found: " + AUTH_PATH)
      return null
    }

    try {
      const text = ctx.host.fs.readText(AUTH_PATH)
      const auth = ctx.util.tryParseJson(text)
      if (auth) {
        ctx.host.log.info("auth loaded from file: " + AUTH_PATH)
      } else {
        ctx.host.log.warn("auth file exists but not valid JSON")
      }
      return auth
    } catch (e) {
      ctx.host.log.warn("auth file read failed: " + String(e))
      return null
    }
  }

  function saveAuth(ctx, auth) {
    try {
      ctx.host.fs.writeText(AUTH_PATH, JSON.stringify(auth, null, 2))
      ctx.host.log.info("auth file updated")
      return true
    } catch (e) {
      ctx.host.log.warn("failed to save auth: " + String(e))
      return false
    }
  }

  function needsRefresh(ctx, accessToken, nowMs) {
    const payload = ctx.jwt.decodePayload(accessToken)
    const expiresAtMs = payload && typeof payload.exp === "number" ? payload.exp * 1000 : null
    return ctx.util.needsRefreshByExpiry({
      nowMs,
      expiresAtMs,
      bufferMs: TOKEN_REFRESH_THRESHOLD_MS,
    })
  }

  function refreshToken(ctx, auth) {
    if (!auth.refresh_token) {
      ctx.host.log.warn("refresh skipped: no refresh token")
      return null
    }

    ctx.host.log.info("attempting token refresh via WorkOS")
    try {
      const resp = ctx.util.request({
        method: "POST",
        url: WORKOS_AUTH_URL,
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        bodyText:
          "grant_type=refresh_token" +
          "&refresh_token=" + encodeURIComponent(auth.refresh_token) +
          "&client_id=" + encodeURIComponent(WORKOS_CLIENT_ID),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        ctx.host.log.error("refresh failed: status=" + resp.status)
        throw "Session expired. Run `droid` to log in again."
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

      // Update auth object with new tokens
      auth.access_token = newAccessToken
      if (body.refresh_token) {
        auth.refresh_token = body.refresh_token
      }

      // Save updated auth
      saveAuth(ctx, auth)
      ctx.host.log.info("refresh succeeded")

      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("refresh exception: " + String(e))
      return null
    }
  }

  function fetchUsage(ctx, accessToken) {
    return ctx.util.request({
      method: "POST",
      url: USAGE_URL,
      headers: {
        Authorization: "Bearer " + accessToken,
        "Content-Type": "application/json",
        Accept: "application/json",
        "User-Agent": "OpenUsage",
      },
      bodyText: JSON.stringify({ useCache: true }),
      timeoutMs: 10000,
    })
  }

  function probe(ctx) {
    const auth = loadAuth(ctx)
    if (!auth) {
      ctx.host.log.error("probe failed: not logged in")
      throw "Not logged in. Run `droid` to authenticate."
    }

    if (!auth.access_token) {
      ctx.host.log.error("probe failed: no access_token in auth file")
      throw "Invalid auth file. Run `droid` to authenticate."
    }

    let accessToken = auth.access_token

    // Check if token needs refresh
    const nowMs = Date.now()
    if (needsRefresh(ctx, accessToken, nowMs)) {
      ctx.host.log.info("token near expiry, refreshing")
      const refreshed = refreshToken(ctx, auth)
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
            return fetchUsage(ctx, token || accessToken)
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
          return refreshToken(ctx, auth)
        },
      })
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("usage request failed: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      ctx.host.log.error("usage returned auth error after all retries: status=" + resp.status)
      throw "Token expired. Run `droid` to log in again."
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

    const usage = data.usage
    if (!usage) {
      throw "Usage response missing data. Try again later."
    }

    const lines = []

    // Calculate reset time and period from usage dates
    const endDate = usage.endDate
    const startDate = usage.startDate
    const resetsAt = typeof endDate === "number" ? ctx.util.toIso(endDate) : null
    const periodDurationMs = (typeof endDate === "number" && typeof startDate === "number")
      ? (endDate - startDate)
      : null

    // Standard tokens (primary line)
    const standard = usage.standard
    if (standard && typeof standard.totalAllowance === "number") {
      const used = standard.orgTotalTokensUsed || 0
      const limit = standard.totalAllowance
      lines.push(ctx.line.progress({
        label: "Standard",
        used: used,
        limit: limit,
        format: { kind: "count", suffix: "tokens" },
        resetsAt: resetsAt,
        periodDurationMs: periodDurationMs,
      }))
    }

    // Premium tokens (detail line, only if plan includes premium)
    const premium = usage.premium
    if (premium && typeof premium.totalAllowance === "number" && premium.totalAllowance > 0) {
      const used = premium.orgTotalTokensUsed || 0
      const limit = premium.totalAllowance
      lines.push(ctx.line.progress({
        label: "Premium",
        used: used,
        limit: limit,
        format: { kind: "count", suffix: "tokens" },
        resetsAt: resetsAt,
        periodDurationMs: periodDurationMs,
      }))
    }

    // Infer plan from allowance
    let plan = null
    if (standard && typeof standard.totalAllowance === "number") {
      const allowance = standard.totalAllowance
      if (allowance >= 200000000) {
        plan = "Max"
      } else if (allowance >= 20000000) {
        plan = "Pro"
      } else if (allowance > 0) {
        plan = "Basic"
      }
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "factory", probe }
})()
