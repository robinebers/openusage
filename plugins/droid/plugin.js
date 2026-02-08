(function () {
  const SESSION_FILES = [
    "~/Library/Application Support/CodexBar/factory-session.json",
    "~/Library/Application Support/com.steipete.codexbar/factory-session.json",
    "~/.factory/auth.encrypted",
  ]
  const MANUAL_COOKIE_FILE = "cookie-header.txt"

  const WORKOS_AUTH_URL = "https://api.workos.com/user_management/authenticate"
  const WORKOS_CLIENT_IDS = [
    "client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7",
    "client_01HNM792M5G5G1A2THWPXKFMXB",
  ]

  const BASE_URLS = [
    "https://auth.factory.ai",
    "https://api.factory.ai",
    "https://app.factory.ai",
  ]

  function joinPath(base, leaf) {
    return String(base || "").replace(/[\\/]+$/, "") + "/" + leaf
  }

  function normalizeCookieHeader(raw) {
    if (typeof raw !== "string") return null
    var text = raw.trim()
    if (!text) return null

    if (text.toLowerCase().startsWith("cookie:")) {
      text = text.slice(7).trim()
    }

    var parts = text
      .split(";")
      .map(function (part) {
        return part.trim()
      })
      .filter(function (part) {
        return part && part.includes("=")
      })

    if (parts.length === 0) return null
    return parts.join("; ")
  }

  function getCookieValue(cookieHeader, cookieName) {
    if (typeof cookieHeader !== "string" || !cookieHeader) return null
    var pairs = cookieHeader.split(";")
    for (var i = 0; i < pairs.length; i += 1) {
      var part = pairs[i].trim()
      var eq = part.indexOf("=")
      if (eq <= 0) continue
      var name = part.slice(0, eq).trim()
      if (name !== cookieName) continue
      var value = part.slice(eq + 1).trim()
      if (value) return value
    }
    return null
  }

  function parseSessionCookies(cookies) {
    if (!Array.isArray(cookies)) return null
    var pairs = []
    for (var i = 0; i < cookies.length; i += 1) {
      var cookie = cookies[i]
      if (!cookie || typeof cookie !== "object") continue
      var name = cookie.Name || cookie.name || cookie.NSHTTPCookieName || cookie.key
      var value = cookie.Value || cookie.value || cookie.NSHTTPCookieValue
      if (typeof name !== "string" || typeof value !== "string") continue
      var n = name.trim()
      var v = value.trim()
      if (!n || !v) continue
      pairs.push(n + "=" + v)
    }
    if (pairs.length === 0) return null
    return pairs.join("; ")
  }

  function readString(value) {
    if (typeof value !== "string") return null
    var trimmed = value.trim()
    return trimmed || null
  }

  function normalizeSessionObject(parsed) {
    if (!parsed || typeof parsed !== "object") return null

    if (Array.isArray(parsed)) {
      return { cookies: parsed }
    }

    var out = {}
    if (Array.isArray(parsed.cookies)) {
      out.cookies = parsed.cookies
    }

    var bearerToken = readString(
      parsed.bearerToken || parsed.accessToken || parsed.access_token || parsed.token
    )
    if (bearerToken) out.bearerToken = bearerToken

    var refreshToken = readString(
      parsed.refreshToken || parsed.refresh_token || parsed.workosRefreshToken
    )
    if (refreshToken) out.refreshToken = refreshToken

    var organizationId = readString(parsed.organizationId || parsed.organization_id)
    if (organizationId) out.organizationId = organizationId

    return out
  }

  function mergeSession(base, extra) {
    var out = typeof base === "object" && base ? base : {}
    if (!extra || typeof extra !== "object") return out

    if (!out.cookies && Array.isArray(extra.cookies)) out.cookies = extra.cookies
    if (!out.bearerToken && readString(extra.bearerToken)) out.bearerToken = extra.bearerToken
    if (!out.refreshToken && readString(extra.refreshToken)) out.refreshToken = extra.refreshToken
    if (!out.organizationId && readString(extra.organizationId)) out.organizationId = extra.organizationId

    return out
  }

  function loadSessionFromFile(ctx, path) {
    if (!ctx.host.fs.exists(path)) return null
    try {
      var raw = ctx.host.fs.readText(path)
      var parsed = ctx.util.tryParseJson(raw)
      return normalizeSessionObject(parsed)
    } catch (e) {
      ctx.host.log.warn("session read failed (" + path + "): " + String(e))
      return null
    }
  }

  function loadSession(ctx) {
    var merged = {}
    for (var i = 0; i < SESSION_FILES.length; i += 1) {
      var fromFile = loadSessionFromFile(ctx, SESSION_FILES[i])
      if (fromFile) {
        merged = mergeSession(merged, fromFile)
      }
    }

    if (!merged.cookies && !merged.bearerToken && !merged.refreshToken && !merged.organizationId) {
      return null
    }

    return merged
  }

  function saveSession(ctx, session) {
    try {
      ctx.host.fs.writeText(SESSION_FILES[0], JSON.stringify(session, null, 2))
    } catch (e) {
      ctx.host.log.warn("session write failed: " + String(e))
    }
  }

  function loadManualCookieHeader(ctx) {
    var path = joinPath(ctx.app.pluginDataDir, MANUAL_COOKIE_FILE)
    if (!ctx.host.fs.exists(path)) return null
    try {
      var raw = ctx.host.fs.readText(path)
      var normalized = normalizeCookieHeader(raw)
      if (!normalized) return null
      ctx.host.log.info("using manual cookie header from pluginDataDir")
      return normalized
    } catch (e) {
      ctx.host.log.warn("manual cookie read failed: " + String(e))
      return null
    }
  }

  function makeError(kind, message) {
    return { kind: kind, message: message }
  }

  function fetchJson(ctx, opts) {
    var resp
    try {
      resp = ctx.util.request(opts)
    } catch (e) {
      return { ok: false, error: makeError("network", String(e)) }
    }

    if (resp.status === 401 || resp.status === 403) {
      return { ok: false, error: makeError("auth", "HTTP " + resp.status) }
    }

    if (resp.status < 200 || resp.status >= 300) {
      return { ok: false, error: makeError("http", "HTTP " + resp.status) }
    }

    var json = ctx.util.tryParseJson(resp.bodyText)
    if (!json) {
      return { ok: false, error: makeError("parse", "Invalid JSON") }
    }

    return { ok: true, data: json }
  }

  function makeFactoryHeaders(cookieHeader, bearerToken) {
    var headers = {
      Accept: "application/json",
      "Content-Type": "application/json",
      Origin: "https://app.factory.ai",
      Referer: "https://app.factory.ai/",
      "x-factory-client": "web-app",
    }

    if (cookieHeader) {
      headers.Cookie = cookieHeader
    }
    if (bearerToken) {
      headers.Authorization = "Bearer " + bearerToken
    }

    return headers
  }

  function fetchFactoryAuth(ctx, baseUrl, cookieHeader, bearerToken) {
    return fetchJson(ctx, {
      method: "GET",
      url: baseUrl + "/api/app/auth/me",
      headers: makeFactoryHeaders(cookieHeader, bearerToken),
      timeoutMs: 15000,
    })
  }

  function fetchFactoryUsage(ctx, baseUrl, cookieHeader, bearerToken, userId) {
    var body = { useCache: true }
    if (typeof userId === "string" && userId.trim()) {
      body.userId = userId.trim()
    }

    return fetchJson(ctx, {
      method: "POST",
      url: baseUrl + "/api/organization/subscription/usage",
      headers: makeFactoryHeaders(cookieHeader, bearerToken),
      bodyText: JSON.stringify(body),
      timeoutMs: 15000,
    })
  }

  function tryFetchAcrossBaseUrls(ctx, cookieHeader, bearerToken) {
    var lastError = null

    for (var i = 0; i < BASE_URLS.length; i += 1) {
      var baseUrl = BASE_URLS[i]
      var authResult = fetchFactoryAuth(ctx, baseUrl, cookieHeader, bearerToken)
      if (!authResult.ok) {
        lastError = authResult.error
        continue
      }

      var usageResult = fetchFactoryUsage(ctx, baseUrl, cookieHeader, bearerToken, null)
      if (!usageResult.ok) {
        lastError = usageResult.error
        continue
      }

      return {
        ok: true,
        baseUrl: baseUrl,
        auth: authResult.data,
        usage: usageResult.data,
      }
    }

    return { ok: false, error: lastError || makeError("auth", "No active session") }
  }

  function refreshWorkOSToken(ctx, refreshToken, organizationId) {
    if (typeof refreshToken !== "string" || !refreshToken.trim()) {
      return null
    }

    var token = refreshToken.trim()

    for (var i = 0; i < WORKOS_CLIENT_IDS.length; i += 1) {
      var clientId = WORKOS_CLIENT_IDS[i]
      var body = {
        client_id: clientId,
        grant_type: "refresh_token",
        refresh_token: token,
      }

      if (typeof organizationId === "string" && organizationId.trim()) {
        body.organization_id = organizationId.trim()
      }

      var result = fetchJson(ctx, {
        method: "POST",
        url: WORKOS_AUTH_URL,
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        bodyText: JSON.stringify(body),
        timeoutMs: 15000,
      })

      if (!result.ok) {
        continue
      }

      var accessToken =
        result.data && typeof result.data.access_token === "string"
          ? result.data.access_token.trim()
          : ""
      if (!accessToken) {
        continue
      }

      var nextRefresh =
        result.data && typeof result.data.refresh_token === "string"
          ? result.data.refresh_token.trim()
          : null

      return {
        accessToken: accessToken,
        refreshToken: nextRefresh,
      }
    }

    return null
  }

  function toEpochMs(ctx, value) {
    var parsed = ctx.util.parseDateMs(value)
    if (!Number.isFinite(parsed)) return null
    var abs = Math.abs(parsed)
    return abs < 1e11 ? parsed * 1000 : parsed
  }

  function clampPercent(value) {
    if (!Number.isFinite(value)) return null
    var clamped = Math.max(0, Math.min(100, value))
    return Math.round(clamped * 100) / 100
  }

  function readUsagePercent(bucket) {
    if (!bucket || typeof bucket !== "object") return null

    var ratio = Number(bucket.usedRatio)
    if (Number.isFinite(ratio)) {
      if (ratio >= 0 && ratio <= 1.1) return clampPercent(ratio * 100)
      if (ratio >= 0 && ratio <= 100) return clampPercent(ratio)
    }

    var used = Number(bucket.userTokens)
    if (!Number.isFinite(used)) {
      used = Number(bucket.orgTotalTokensUsed)
    }

    var allowance = Number(bucket.totalAllowance)
    if (!Number.isFinite(allowance) || allowance <= 0) {
      var basic = Number(bucket.basicAllowance)
      var overage = Number(bucket.orgOverageLimit)
      if (Number.isFinite(basic) && Number.isFinite(overage)) {
        allowance = basic + overage
      }
    }

    if (Number.isFinite(used) && Number.isFinite(allowance) && allowance > 0) {
      return clampPercent((used / allowance) * 100)
    }

    return null
  }

  function buildPlan(ctx, auth) {
    var tier =
      auth && auth.organization && auth.organization.subscription
        ? auth.organization.subscription.factoryTier
        : null
    var planName =
      auth && auth.organization && auth.organization.subscription && auth.organization.subscription.orbSubscription && auth.organization.subscription.orbSubscription.plan
        ? auth.organization.subscription.orbSubscription.plan.name
        : null

    var parts = []
    if (typeof tier === "string" && tier.trim()) {
      parts.push("Droid " + ctx.fmt.planLabel(tier.trim()))
    }
    if (
      typeof planName === "string" &&
      planName.trim() &&
      !planName.toLowerCase().includes("factory")
    ) {
      parts.push(planName.trim())
    }

    if (parts.length > 0) return parts.join(" - ")

    var fallback =
      typeof planName === "string" && planName.trim()
        ? planName.trim()
        : typeof tier === "string" && tier.trim()
          ? tier.trim()
          : ""

    var formatted = ctx.fmt.planLabel(fallback)
    return formatted || null
  }

  function probe(ctx) {
    var manualCookieHeader = loadManualCookieHeader(ctx)
    var session = loadSession(ctx) || {}

    var sessionCookieHeader = parseSessionCookies(session.cookies)
    var cookieHeader = manualCookieHeader || sessionCookieHeader
    var bearerToken =
      (typeof session.bearerToken === "string" && session.bearerToken.trim()) ||
      getCookieValue(cookieHeader, "access-token") ||
      null
    var refreshToken =
      typeof session.refreshToken === "string" && session.refreshToken.trim()
        ? session.refreshToken.trim()
        : null

    if (!cookieHeader && !bearerToken && !refreshToken) {
      throw "Not logged in. Sign in at app.factory.ai or add cookie-header.txt in OpenUsage Droid plugin data."
    }

    var result = tryFetchAcrossBaseUrls(ctx, cookieHeader, bearerToken)

    if (!result.ok && cookieHeader && bearerToken && result.error && result.error.kind === "auth") {
      result = tryFetchAcrossBaseUrls(ctx, cookieHeader, null)
    }

    var refreshed = null
    if (!result.ok && refreshToken) {
      refreshed = refreshWorkOSToken(ctx, refreshToken, session.organizationId)
      if (refreshed && refreshed.accessToken) {
        bearerToken = refreshed.accessToken
        if (refreshed.refreshToken) {
          refreshToken = refreshed.refreshToken
        }
        result = tryFetchAcrossBaseUrls(ctx, cookieHeader, bearerToken)
      }
    }

    if (!result.ok) {
      if (result.error && result.error.kind === "auth") {
        throw "Session expired. Sign in again at app.factory.ai."
      }
      var reason = result.error && result.error.message ? result.error.message : "Unknown error"
      throw "Droid usage request failed: " + reason
    }

    var auth = result.auth || {}
    var usagePayload = result.usage && typeof result.usage.usage === "object"
      ? result.usage.usage
      : result.usage || {}

    var startMs = toEpochMs(ctx, usagePayload.startDate)
    var endMs = toEpochMs(ctx, usagePayload.endDate)
    var resetsAt = Number.isFinite(endMs) ? ctx.util.toIso(endMs) : null
    var periodDurationMs =
      Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs
        ? endMs - startMs
        : null

    var lines = []

    var standardPercent = readUsagePercent(usagePayload.standard)
    if (standardPercent !== null) {
      lines.push(
        ctx.line.progress({
          label: "Standard",
          used: standardPercent,
          limit: 100,
          format: { kind: "percent" },
          resetsAt: resetsAt || undefined,
          periodDurationMs: periodDurationMs || undefined,
        })
      )
    }

    var premiumPercent = readUsagePercent(usagePayload.premium)
    if (premiumPercent !== null) {
      lines.push(
        ctx.line.progress({
          label: "Premium",
          used: premiumPercent,
          limit: 100,
          format: { kind: "percent" },
          resetsAt: resetsAt || undefined,
          periodDurationMs: periodDurationMs || undefined,
        })
      )
    }

    var organizationName = auth && auth.organization ? auth.organization.name : null
    if (typeof organizationName === "string" && organizationName.trim()) {
      lines.push(
        ctx.line.text({
          label: "Organization",
          value: organizationName.trim(),
        })
      )
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    if (!manualCookieHeader && (refreshed || bearerToken || refreshToken)) {
      var nextSession = typeof session === "object" && session ? session : {}
      if (bearerToken) nextSession.bearerToken = bearerToken
      if (refreshToken) nextSession.refreshToken = refreshToken
      saveSession(ctx, nextSession)
    }

    return {
      plan: buildPlan(ctx, auth),
      lines: lines,
    }
  }

  globalThis.__openusage_plugin = { id: "droid", probe: probe }
})()
