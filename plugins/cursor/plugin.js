(function () {
  const STATE_DB =
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  const KEYCHAIN_ACCESS_TOKEN_SERVICE = "cursor-access-token"
  const KEYCHAIN_REFRESH_TOKEN_SERVICE = "cursor-refresh-token"
  const BASE_URL = "https://api2.cursor.sh"
  const USAGE_URL = BASE_URL + "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
  const PLAN_URL = BASE_URL + "/aiserver.v1.DashboardService/GetPlanInfo"
  const REFRESH_URL = BASE_URL + "/oauth/token"
  const CREDITS_URL = BASE_URL + "/aiserver.v1.DashboardService/GetCreditGrantsBalance"
  const REST_USAGE_URL = "https://cursor.com/api/usage"
  const CLIENT_ID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
  const REFRESH_BUFFER_MS = 5 * 60 * 1000 // refresh 5 minutes before expiration
  const LOGIN_HINT = "Sign in via Cursor app or run `agent login`."

  function readStateValue(ctx, key) {
    try {
      const sql =
        "SELECT value FROM ItemTable WHERE key = '" + key + "' LIMIT 1;"
      const json = ctx.host.sqlite.query(STATE_DB, sql)
      const rows = ctx.util.tryParseJson(json)
      if (!Array.isArray(rows)) {
        throw new Error("sqlite returned invalid json")
      }
      if (rows.length > 0 && rows[0].value) {
        return rows[0].value
      }
    } catch (e) {
      ctx.host.log.warn("sqlite read failed for " + key + ": " + String(e))
    }
    return null
  }

  function writeStateValue(ctx, key, value) {
    try {
      // Escape single quotes in value for SQL
      const escaped = String(value).replace(/'/g, "''")
      const sql =
        "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('" +
        key +
        "', '" +
        escaped +
        "');"
      ctx.host.sqlite.exec(STATE_DB, sql)
      return true
    } catch (e) {
      ctx.host.log.warn("sqlite write failed for " + key + ": " + String(e))
      return false
    }
  }

  function readKeychainValue(ctx, service) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readGenericPassword !== "function") {
      return null
    }
    try {
      const value = ctx.host.keychain.readGenericPassword(service)
      if (typeof value !== "string") return null
      const trimmed = value.trim()
      return trimmed || null
    } catch (e) {
      ctx.host.log.info("keychain read failed for " + service + ": " + String(e))
      return null
    }
  }

  function writeKeychainValue(ctx, service, value) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.writeGenericPassword !== "function") {
      ctx.host.log.warn("keychain write unsupported")
      return false
    }
    try {
      ctx.host.keychain.writeGenericPassword(service, String(value))
      return true
    } catch (e) {
      ctx.host.log.warn("keychain write failed for " + service + ": " + String(e))
      return false
    }
  }

  function loadAuthState(ctx) {
    const sqliteAccessToken = readStateValue(ctx, "cursorAuth/accessToken")
    const sqliteRefreshToken = readStateValue(ctx, "cursorAuth/refreshToken")
    if (sqliteAccessToken || sqliteRefreshToken) {
      return {
        accessToken: sqliteAccessToken,
        refreshToken: sqliteRefreshToken,
        source: "sqlite",
      }
    }

    const keychainAccessToken = readKeychainValue(ctx, KEYCHAIN_ACCESS_TOKEN_SERVICE)
    const keychainRefreshToken = readKeychainValue(ctx, KEYCHAIN_REFRESH_TOKEN_SERVICE)
    if (keychainAccessToken || keychainRefreshToken) {
      return {
        accessToken: keychainAccessToken,
        refreshToken: keychainRefreshToken,
        source: "keychain",
      }
    }

    return {
      accessToken: null,
      refreshToken: null,
      source: null,
    }
  }

  function persistAccessToken(ctx, source, accessToken) {
    if (source === "keychain") {
      return writeKeychainValue(ctx, KEYCHAIN_ACCESS_TOKEN_SERVICE, accessToken)
    }
    return writeStateValue(ctx, "cursorAuth/accessToken", accessToken)
  }

  function getTokenExpiration(ctx, token) {
    const payload = ctx.jwt.decodePayload(token)
    if (!payload || typeof payload.exp !== "number") return null
    return payload.exp * 1000 // Convert to milliseconds
  }

  function needsRefresh(ctx, accessToken, nowMs) {
    if (!accessToken) return true
    const expiresAt = getTokenExpiration(ctx, accessToken)
    return ctx.util.needsRefreshByExpiry({
      nowMs,
      expiresAtMs: expiresAt,
      bufferMs: REFRESH_BUFFER_MS,
    })
  }

  function refreshToken(ctx, refreshTokenValue, source) {
    if (!refreshTokenValue) {
      ctx.host.log.warn("refresh skipped: no refresh token")
      return null
    }

    ctx.host.log.info("attempting token refresh")
    try {
      const resp = ctx.util.request({
        method: "POST",
        url: REFRESH_URL,
        headers: { "Content-Type": "application/json" },
        bodyText: JSON.stringify({
          grant_type: "refresh_token",
          client_id: CLIENT_ID,
          refresh_token: refreshTokenValue,
        }),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        let errorInfo = null
        errorInfo = ctx.util.tryParseJson(resp.bodyText)
        const shouldLogout = errorInfo && errorInfo.shouldLogout === true
        ctx.host.log.error("refresh failed: status=" + resp.status + " shouldLogout=" + shouldLogout)
        if (shouldLogout) {
          throw "Session expired. " + LOGIN_HINT
        }
        throw "Token expired. " + LOGIN_HINT
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

      // Check if server wants us to logout
      if (body.shouldLogout === true) {
        ctx.host.log.error("refresh response indicates shouldLogout=true")
        throw "Session expired. " + LOGIN_HINT
      }

      const newAccessToken = body.access_token
      if (!newAccessToken) {
        ctx.host.log.warn("refresh response missing access_token")
        return null
      }

      // Persist updated access token to source where auth was loaded from.
      persistAccessToken(ctx, source, newAccessToken)
      ctx.host.log.info("refresh succeeded, token persisted")

      // Note: Cursor refresh returns access_token which is used as both
      // access and refresh token in some flows
      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("refresh exception: " + String(e))
      return null
    }
  }

  function connectPost(ctx, url, token) {
    return ctx.util.request({
      method: "POST",
      url: url,
      headers: {
        Authorization: "Bearer " + token,
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
      },
      bodyText: "{}",
      timeoutMs: 10000,
    })
  }

  function buildSessionToken(ctx, accessToken) {
    var payload = ctx.jwt.decodePayload(accessToken)
    if (!payload || !payload.sub) return null
    var parts = String(payload.sub).split("|")
    var userId = parts.length > 1 ? parts[1] : parts[0]
    if (!userId) return null
    return { userId: userId, sessionToken: userId + "%3A%3A" + accessToken }
  }

  function fetchEnterpriseUsage(ctx, accessToken) {
    var session = buildSessionToken(ctx, accessToken)
    if (!session) {
      ctx.host.log.warn("enterprise: cannot build session token")
      return null
    }
    try {
      var resp = ctx.util.request({
        method: "GET",
        url: REST_USAGE_URL + "?user=" + encodeURIComponent(session.userId),
        headers: {
          Cookie: "WorkosCursorSessionToken=" + session.sessionToken,
        },
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("enterprise usage returned status=" + resp.status)
        return null
      }
      return ctx.util.tryParseJson(resp.bodyText)
    } catch (e) {
      ctx.host.log.warn("enterprise usage fetch failed: " + String(e))
      return null
    }
  }

  function buildEnterpriseResult(ctx, accessToken, planName, usage) {
    var requestUsage = fetchEnterpriseUsage(ctx, accessToken)
    var lines = []

    if (requestUsage) {
      var gpt4 = requestUsage["gpt-4"]
      if (gpt4 && typeof gpt4.maxRequestUsage === "number" && gpt4.maxRequestUsage > 0) {
        var used = gpt4.numRequests || 0
        var limit = gpt4.maxRequestUsage

        var billingPeriodMs = 30 * 24 * 60 * 60 * 1000
        var cycleStart = requestUsage.startOfMonth
          ? ctx.util.parseDateMs(requestUsage.startOfMonth)
          : null
        var cycleEndMs = cycleStart ? cycleStart + billingPeriodMs : null

        lines.push(ctx.line.progress({
          label: "Requests",
          used: used,
          limit: limit,
          format: { kind: "count", suffix: "requests" },
          resetsAt: ctx.util.toIso(cycleEndMs),
          periodDurationMs: billingPeriodMs,
        }))
      }
    }

    if (lines.length === 0) {
      ctx.host.log.warn("enterprise: no usage data available")
      throw "Enterprise usage data unavailable. Try again later."
    }

    var plan = null
    if (planName) {
      var planLabel = ctx.fmt.planLabel(planName)
      if (planLabel) plan = planLabel
    }

    return { plan: plan, lines: lines }
  }

  function probe(ctx) {
    const authState = loadAuthState(ctx)
    let accessToken = authState.accessToken
    const refreshTokenValue = authState.refreshToken
    const authSource = authState.source

    if (!accessToken && !refreshTokenValue) {
      ctx.host.log.error("probe failed: no access or refresh token in sqlite/keychain")
      throw "Not logged in. " + LOGIN_HINT
    }

    ctx.host.log.info("tokens loaded from " + authSource + ": accessToken=" + (accessToken ? "yes" : "no") + " refreshToken=" + (refreshTokenValue ? "yes" : "no"))

    const nowMs = Date.now()

    // Proactively refresh if token is expired or about to expire
    if (needsRefresh(ctx, accessToken, nowMs)) {
      ctx.host.log.info("token needs refresh (expired or expiring soon)")
      let refreshed = null
      try {
        refreshed = refreshToken(ctx, refreshTokenValue, authSource)
      } catch (e) {
        // If refresh fails but we have an access token, try it anyway
        ctx.host.log.warn("refresh failed but have access token, will try: " + String(e))
        if (!accessToken) throw e
      }
      if (refreshed) {
        accessToken = refreshed
      } else if (!accessToken) {
        ctx.host.log.error("refresh failed and no access token available")
        throw "Not logged in. " + LOGIN_HINT
      }
    }

    let usageResp
    let didRefresh = false
    try {
      usageResp = ctx.util.retryOnceOnAuth({
        request: (token) => {
          try {
            return connectPost(ctx, USAGE_URL, token || accessToken)
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
          const refreshed = refreshToken(ctx, refreshTokenValue, authSource)
          if (refreshed) accessToken = refreshed
          return refreshed
        },
      })
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("usage request failed: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(usageResp.status)) {
      ctx.host.log.error("usage returned auth error after all retries: status=" + usageResp.status)
      throw "Token expired. " + LOGIN_HINT
    }

    if (usageResp.status < 200 || usageResp.status >= 300) {
      ctx.host.log.error("usage returned error: status=" + usageResp.status)
      throw "Usage request failed (HTTP " + String(usageResp.status) + "). Try again later."
    }

    ctx.host.log.info("usage fetch succeeded")

    const usage = ctx.util.tryParseJson(usageResp.bodyText)
    if (usage === null) {
      throw "Usage response invalid. Try again later."
    }

    // Fetch plan info early (needed for Enterprise detection)
    let planName = ""
    try {
      const planResp = connectPost(ctx, PLAN_URL, accessToken)
      if (planResp.status >= 200 && planResp.status < 300) {
        const plan = ctx.util.tryParseJson(planResp.bodyText)
        if (plan && plan.planInfo && plan.planInfo.planName) {
          planName = plan.planInfo.planName
        }
      }
    } catch (e) {
      ctx.host.log.warn("plan info fetch failed: " + String(e))
    }

    // Enterprise accounts return no planUsage from the Connect API.
    // Detect Enterprise and use the REST usage API instead.
    const isEnterprise = !usage.planUsage && planName.toLowerCase() === "enterprise"
    if (isEnterprise) {
      ctx.host.log.info("detected enterprise account, using REST usage API")
      return buildEnterpriseResult(ctx, accessToken, planName, usage)
    }

    // Team plans may omit `enabled` even with valid plan usage data.
    if (usage.enabled === false || !usage.planUsage) {
      throw "No active Cursor subscription."
    }

    let creditGrants = null
    try {
      const creditsResp = connectPost(ctx, CREDITS_URL, accessToken)
      if (creditsResp.status >= 200 && creditsResp.status < 300) {
        creditGrants = ctx.util.tryParseJson(creditsResp.bodyText)
      }
    } catch (e) {
      ctx.host.log.warn("credit grants fetch failed: " + String(e))
    }

    let plan = null
    if (planName) {
      const planLabel = ctx.fmt.planLabel(planName)
      if (planLabel) {
        plan = planLabel
      }
    }

    const lines = []
    const pu = usage.planUsage

    // Credits first (if available) - highest priority primary metric
    if (creditGrants && creditGrants.hasCreditGrants === true) {
      const total = parseInt(creditGrants.totalCents, 10)
      const used = parseInt(creditGrants.usedCents, 10)
      if (total > 0 && !isNaN(total) && !isNaN(used)) {
        lines.push(ctx.line.progress({
          label: "Credits",
          used: ctx.fmt.dollars(used),
          limit: ctx.fmt.dollars(total),
          format: { kind: "dollars" },
        }))
      }
    }

    // Total usage (always present) - fallback primary metric
    if (typeof pu.limit !== "number") {
      throw "Total usage limit missing from API response."
    }
    const planUsed = typeof pu.totalSpend === "number"
      ? pu.totalSpend
      : pu.limit - (pu.remaining ?? 0)
    const computedPercentUsed = pu.limit > 0
      ? (planUsed / pu.limit) * 100
      : 0
    const totalUsagePercent = Number.isFinite(pu.totalPercentUsed)
      ? pu.totalPercentUsed
      : computedPercentUsed

    // Calculate billing cycle period duration
    var billingPeriodMs = 30 * 24 * 60 * 60 * 1000 // 30 days default
    var cycleStart = Number(usage.billingCycleStart)
    var cycleEnd = Number(usage.billingCycleEnd)
    if (Number.isFinite(cycleStart) && Number.isFinite(cycleEnd) && cycleEnd > cycleStart) {
      billingPeriodMs = cycleEnd - cycleStart // already in ms
    }

    const su = usage.spendLimitUsage
    const isTeamAccount = (
      (typeof planName === "string" && planName.toLowerCase() === "team") ||
      (su && su.limitType === "team") ||
      (su && typeof su.pooledLimit === "number")
    )

    if (isTeamAccount) {
      lines.push(ctx.line.progress({
        label: "Total usage",
        used: ctx.fmt.dollars(planUsed),
        limit: ctx.fmt.dollars(pu.limit),
        format: { kind: "dollars" },
        resetsAt: ctx.util.toIso(usage.billingCycleEnd),
        periodDurationMs: billingPeriodMs
      }))

      if (typeof pu.bonusSpend === "number" && pu.bonusSpend > 0) {
        lines.push(ctx.line.text({ label: "Bonus spend", value: "$" + String(ctx.fmt.dollars(pu.bonusSpend)) }))
      }
    } else {
      lines.push(ctx.line.progress({
        label: "Total usage",
        used: totalUsagePercent,
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(usage.billingCycleEnd),
        periodDurationMs: billingPeriodMs
      }))
    }

    if (typeof pu.autoPercentUsed === "number" && Number.isFinite(pu.autoPercentUsed)) {
      lines.push(ctx.line.progress({
        label: "Auto usage",
        used: pu.autoPercentUsed,
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(usage.billingCycleEnd),
        periodDurationMs: billingPeriodMs
      }))
    }

    if (typeof pu.apiPercentUsed === "number" && Number.isFinite(pu.apiPercentUsed)) {
      lines.push(ctx.line.progress({
        label: "API usage",
        used: pu.apiPercentUsed,
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(usage.billingCycleEnd),
        periodDurationMs: billingPeriodMs
      }))
    }

    // On-demand (if available) - not a primary candidate
    if (su) {
      const limit = su.individualLimit ?? su.pooledLimit ?? 0
      const remaining = su.individualRemaining ?? su.pooledRemaining ?? 0
      if (limit > 0) {
        const used = limit - remaining
        lines.push(ctx.line.progress({
          label: "On-demand",
          used: ctx.fmt.dollars(used),
          limit: ctx.fmt.dollars(limit),
          format: { kind: "dollars" },
        }))
      }
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "cursor", probe }
})()
