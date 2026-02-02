(function () {
  const CRED_FILE = "~/.claude/.credentials.json"
  const KEYCHAIN_SERVICE = "Claude Code-credentials"
  const USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
  const REFRESH_URL = "https://platform.claude.com/v1/oauth/token"
  const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  const SCOPES = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
  const REFRESH_BUFFER_MS = 5 * 60 * 1000 // refresh 5 minutes before expiration

  function loadCredentials(ctx) {
    // Try file first
    if (ctx.host.fs.exists(CRED_FILE)) {
      try {
        const text = ctx.host.fs.readText(CRED_FILE)
        const parsed = JSON.parse(text)
        const oauth = parsed.claudeAiOauth
        if (oauth && oauth.accessToken) {
          return { oauth, source: "file", fullData: parsed }
        }
      } catch (e) {
      }
    }

    // Try keychain fallback
    try {
      const keychainValue = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE)
      if (keychainValue) {
        const parsed = JSON.parse(keychainValue)
        const oauth = parsed.claudeAiOauth
        if (oauth && oauth.accessToken) {
          return { oauth, source: "keychain", fullData: parsed }
        }
      }
    } catch (e) {
    }

    return null
  }

  function saveCredentials(ctx, source, fullData) {
    const text = JSON.stringify(fullData, null, 2)
    if (source === "file") {
      try {
        ctx.host.fs.writeText(CRED_FILE, text)
      } catch (e) {
        ctx.host.log.error("Failed to write Claude credentials file: " + String(e))
      }
    } else if (source === "keychain") {
      try {
        ctx.host.keychain.writeGenericPassword(KEYCHAIN_SERVICE, text)
      } catch (e) {
        ctx.host.log.error("Failed to write Claude credentials keychain: " + String(e))
      }
    }
  }

  function needsRefresh(oauth, nowMs) {
    if (!oauth.expiresAt) return true
    const expiresAt = Number(oauth.expiresAt)
    if (!Number.isFinite(expiresAt)) return true
    return nowMs + REFRESH_BUFFER_MS >= expiresAt
  }

  function refreshToken(ctx, creds) {
    const { oauth, source, fullData } = creds
    if (!oauth.refreshToken) return null

    try {
      const resp = ctx.host.http.request({
        method: "POST",
        url: REFRESH_URL,
        headers: { "Content-Type": "application/json" },
        bodyText: JSON.stringify({
          grant_type: "refresh_token",
          refresh_token: oauth.refreshToken,
          client_id: CLIENT_ID,
          scope: SCOPES,
        }),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        let errorCode = null
        try {
          const body = JSON.parse(resp.bodyText)
          errorCode = body.error || body.error_description
        } catch {}
        if (errorCode === "invalid_grant") {
          throw "Session expired. Run `claude` to log in again."
        }
        throw "Token expired. Run `claude` to log in again."
      }
      if (resp.status < 200 || resp.status >= 300) return null

      const body = JSON.parse(resp.bodyText)
      const newAccessToken = body.access_token
      if (!newAccessToken) return null

      // Update oauth credentials
      oauth.accessToken = newAccessToken
      if (body.refresh_token) oauth.refreshToken = body.refresh_token
      if (typeof body.expires_in === "number") {
        oauth.expiresAt = Date.now() + body.expires_in * 1000
      }

      // Persist updated credentials
      fullData.claudeAiOauth = oauth
      saveCredentials(ctx, source, fullData)

      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      return null
    }
  }

  function fetchUsage(ctx, accessToken) {
    return ctx.host.http.request({
      method: "GET",
      url: USAGE_URL,
      headers: {
        Authorization: "Bearer " + accessToken.trim(),
        Accept: "application/json",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "OpenUsage",
      },
      timeoutMs: 10000,
    })
  }

  function getResetInFromIso(ctx, isoString) {
    if (!isoString) return null
    const ts = Date.parse(isoString)
    if (!Number.isFinite(ts)) return null
    const diffSeconds = Math.floor((ts - Date.now()) / 1000)
    return ctx.fmt.resetIn(diffSeconds)
  }

  function probe(ctx) {
    const creds = loadCredentials(ctx)
    if (!creds || !creds.oauth || !creds.oauth.accessToken || !creds.oauth.accessToken.trim()) {
      throw "Not logged in. Run `claude` to authenticate."
    }

    const nowMs = Date.now()
    let accessToken = creds.oauth.accessToken

    // Proactively refresh if token is expired or about to expire
    if (needsRefresh(creds.oauth, nowMs)) {
      const refreshed = refreshToken(ctx, creds)
      if (refreshed) accessToken = refreshed
    }

    let resp
    try {
      resp = fetchUsage(ctx, accessToken)
    } catch (e) {
      throw "Usage request failed. Check your connection."
    }

    // On 401/403, try refreshing once and retry
    if (resp.status === 401 || resp.status === 403) {
      const refreshed = refreshToken(ctx, creds)
      if (!refreshed) {
        throw "Token expired. Run `claude` to log in again."
      }
      try {
        resp = fetchUsage(ctx, refreshed)
      } catch (e) {
        throw "Usage request failed after refresh. Try again."
      }
      if (resp.status === 401 || resp.status === 403) {
        throw "Token expired. Run `claude` to log in again."
      }
    }

    if (resp.status < 200 || resp.status >= 300) {
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    let data
    try {
      data = JSON.parse(resp.bodyText)
    } catch {
      throw "Usage response invalid. Try again later."
    }

    const lines = []
    var plan = null
    if (creds.oauth.subscriptionType) {
      var planLabel = ctx.fmt.planLabel(creds.oauth.subscriptionType)
      if (planLabel) {
        plan = planLabel
      }
    }

    if (data.five_hour && typeof data.five_hour.utilization === "number") {
      const resetIn = getResetInFromIso(ctx, data.five_hour.resets_at)
      lines.push(ctx.line.progress({
        label: "Session",
        value: data.five_hour.utilization,
        max: 100,
        unit: "percent",
        subtitle: resetIn ? "Resets in " + resetIn : null
      }))
    }
    if (data.seven_day && typeof data.seven_day.utilization === "number") {
      const resetIn = getResetInFromIso(ctx, data.seven_day.resets_at)
      lines.push(ctx.line.progress({
        label: "Weekly",
        value: data.seven_day.utilization,
        max: 100,
        unit: "percent",
        subtitle: resetIn ? "Resets in " + resetIn : null
      }))
    }
    if (data.seven_day_sonnet && typeof data.seven_day_sonnet.utilization === "number") {
      const resetIn = getResetInFromIso(ctx, data.seven_day_sonnet.resets_at)
      lines.push(ctx.line.progress({
        label: "Sonnet",
        value: data.seven_day_sonnet.utilization,
        max: 100,
        unit: "percent",
        subtitle: resetIn ? "Resets in " + resetIn : null
      }))
    }
    if (data.seven_day_opus && typeof data.seven_day_opus.utilization === "number") {
      const resetIn = getResetInFromIso(ctx, data.seven_day_opus.resets_at)
      lines.push(ctx.line.progress({
        label: "Opus",
        value: data.seven_day_opus.utilization,
        max: 100,
        unit: "percent",
        subtitle: resetIn ? "Resets in " + resetIn : null
      }))
    }

    if (data.extra_usage && data.extra_usage.is_enabled) {
      const used = data.extra_usage.used_credits
      const limit = data.extra_usage.monthly_limit
      if (typeof used === "number" && typeof limit === "number" && limit > 0) {
        lines.push(ctx.line.progress({
          label: "Extra usage",
          value: ctx.fmt.dollars(used),
          max: ctx.fmt.dollars(limit),
          unit: "dollars"
        }))
      } else if (typeof used === "number" && used > 0) {
        lines.push(ctx.line.text({ label: "Extra usage", value: "$" + String(ctx.fmt.dollars(used)) }))
      }
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "claude", probe }
})()
