(function () {
  var API_URL = "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo"
  var KEYCHAIN_SERVICE = "dev.warp.Warp-Stable"
  var KEYCHAIN_ACCOUNT = "User"
  var API_KEY_FILE = "api-key.txt"

  var QUERY = "query GetRequestLimitInfo($requestContext: RequestContext!) { user(requestContext: $requestContext) { __typename ... on UserOutput { user { requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh } bonusGrants { requestCreditsGranted requestCreditsRemaining expiration } workspaces { bonusGrantsInfo { grants { requestCreditsGranted requestCreditsRemaining expiration } } } } } } }"

  function loadTokenFromKeychain(ctx) {
    try {
      var json = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)
      var data = ctx.util.tryParseJson(json)
      if (!data) {
        ctx.host.log.warn("keychain entry not valid JSON")
        return null
      }
      var idToken = data.id_token
      if (idToken && typeof idToken === "object" && idToken.id_token) {
        ctx.host.log.info("using token from macOS Keychain")
        return idToken.id_token
      }
      ctx.host.log.warn("keychain entry missing id_token")
      return null
    } catch (e) {
      ctx.host.log.info("keychain read failed (expected if not logged in): " + String(e))
      return null
    }
  }

  function loadToken(ctx) {
    // 1. macOS Keychain (auto — reads from Warp app's stored credentials)
    var keychainToken = loadTokenFromKeychain(ctx)
    if (keychainToken) return keychainToken

    // 2. WARP_API_KEY env var
    if (ctx.host.env && typeof ctx.host.env.get === "function") {
      try {
        var envKey = ctx.host.env.get("WARP_API_KEY")
        if (typeof envKey === "string" && envKey.trim()) {
          ctx.host.log.info("using WARP_API_KEY env var")
          return envKey.trim()
        }
      } catch (e) {
        ctx.host.log.warn("WARP_API_KEY read failed: " + String(e))
      }

      // 3. WARP_TOKEN env var
      try {
        var envToken = ctx.host.env.get("WARP_TOKEN")
        if (typeof envToken === "string" && envToken.trim()) {
          ctx.host.log.info("using WARP_TOKEN env var")
          return envToken.trim()
        }
      } catch (e) {
        ctx.host.log.warn("WARP_TOKEN read failed: " + String(e))
      }
    }

    // 4. File fallback: {pluginDataDir}/api-key.txt
    var filePath = ctx.app.pluginDataDir + "/" + API_KEY_FILE
    if (ctx.host.fs.exists(filePath)) {
      try {
        var text = ctx.host.fs.readText(filePath)
        var trimmed = (text || "").trim()
        if (trimmed) {
          ctx.host.log.info("using API key from file: " + filePath)
          return trimmed
        }
      } catch (e) {
        ctx.host.log.warn("API key file read failed: " + String(e))
      }
    }

    return null
  }

  function fetchUsage(ctx, token) {
    var body = JSON.stringify({
      query: QUERY,
      variables: {
        requestContext: {
          clientContext: { version: "openusage" },
          osContext: { category: "macOS", name: "macOS", version: "0", linuxKernelVersion: null }
        }
      },
      operationName: "GetRequestLimitInfo"
    })

    try {
      return ctx.util.request({
        method: "POST",
        url: API_URL,
        headers: {
          "Authorization": "Bearer " + token,
          "Content-Type": "application/json",
          "x-warp-client-id": "warp-app"
        },
        bodyText: body,
        timeoutMs: 10000
      })
    } catch (e) {
      ctx.host.log.error("request failed: " + String(e))
      throw "Request failed. Check your connection."
    }
  }

  function probe(ctx) {
    var token = loadToken(ctx)
    if (!token) {
      throw "Not logged in. Sign in to Warp to see your usage."
    }

    var resp = fetchUsage(ctx, token)

    if (resp.status === 401 || resp.status === 403) {
      ctx.host.log.error("auth error: status=" + resp.status)
      throw "Session expired. Restart Warp to refresh your session."
    }

    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.error("API error: status=" + resp.status)
      throw "Warp API error (HTTP " + resp.status + "). Try again later."
    }

    var data = ctx.util.tryParseJson(resp.bodyText)
    if (!data) {
      throw "Invalid response from Warp API. Try again later."
    }

    // Navigate to user data
    var userData = data.data && data.data.user && data.data.user.user
    if (!userData) {
      ctx.host.log.warn("unexpected response shape")
      throw "Unexpected response from Warp API. Try again later."
    }

    var lines = []
    var limitInfo = userData.requestLimitInfo

    if (limitInfo) {
      if (limitInfo.isUnlimited) {
        lines.push(ctx.line.badge({ label: "Credits", text: "Unlimited", color: "#938BB4" }))
      } else {
        var used = limitInfo.requestsUsedSinceLastRefresh || 0
        var limit = limitInfo.requestLimit || 0
        var resetsAt = limitInfo.nextRefreshTime ? ctx.util.toIso(limitInfo.nextRefreshTime) : null

        if (limit > 0) {
          var progressOpts = {
            label: "Credits",
            used: used,
            limit: limit,
            format: { kind: "count", suffix: "requests" }
          }
          if (resetsAt) {
            progressOpts.resetsAt = resetsAt
            // Warp uses a monthly billing cycle
            progressOpts.periodDurationMs = 30 * 24 * 60 * 60 * 1000
          }
          lines.push(ctx.line.progress(progressOpts))
        }
      }
    }

    // Combine user + workspace bonus grants
    var totalBonusGranted = 0
    var totalBonusRemaining = 0

    var userGrants = userData.bonusGrants
    if (userGrants && userGrants.length) {
      for (var i = 0; i < userGrants.length; i++) {
        var g = userGrants[i]
        totalBonusGranted += (g.requestCreditsGranted || 0)
        totalBonusRemaining += (g.requestCreditsRemaining || 0)
      }
    }

    var workspaces = userData.workspaces
    if (workspaces && workspaces.length) {
      for (var w = 0; w < workspaces.length; w++) {
        var ws = workspaces[w]
        var grants = ws.bonusGrantsInfo && ws.bonusGrantsInfo.grants
        if (grants && grants.length) {
          for (var j = 0; j < grants.length; j++) {
            var wg = grants[j]
            totalBonusGranted += (wg.requestCreditsGranted || 0)
            totalBonusRemaining += (wg.requestCreditsRemaining || 0)
          }
        }
      }
    }

    if (totalBonusGranted > 0) {
      var bonusUsed = totalBonusGranted - totalBonusRemaining
      lines.push(ctx.line.progress({
        label: "Bonus",
        used: bonusUsed,
        limit: totalBonusGranted,
        format: { kind: "count", suffix: "credits" }
      }))
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan: null, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "warp", probe: probe }
})()
