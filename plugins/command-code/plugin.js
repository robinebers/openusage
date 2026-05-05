(function () {
  var SECRETS_FILE = "~/.commandcode/auth.json"
  var SECRETS_KEY = "apiKey"
  var CREDITS_URL = "https://api.commandcode.ai/alpha/billing/credits"
  var SUBS_URL = "https://api.commandcode.ai/alpha/billing/subscriptions"

  var PLAN_LIMITS = {
    "individual-go": 10,
    "individual-pro": 30,
    "individual-max": 150,
    "individual-ultra": 300,
    "teams-pro": 40,
  }

  var PLAN_LABELS = {
    "individual-go": "Go",
    "individual-pro": "Pro",
    "individual-max": "Max",
    "individual-ultra": "Ultra",
    "teams-pro": "Teams Pro",
  }

  function loadApiKey(ctx) {
    if (!ctx.host.fs.exists(SECRETS_FILE)) return null
    try {
      var text = ctx.host.fs.readText(SECRETS_FILE)
      var parsed = ctx.util.tryParseJson(text)
      if (parsed && parsed[SECRETS_KEY]) {
        ctx.host.log.info("api key loaded from secrets file")
        return parsed[SECRETS_KEY]
      }
    } catch (e) {
      ctx.host.log.warn("secrets file read failed: " + String(e))
    }
    return null
  }

  function fetchCredits(ctx, apiKey) {
    return ctx.util.requestJson({
      method: "GET",
      url: CREDITS_URL,
      headers: {
        "Authorization": "Bearer " + apiKey,
        "Content-Type": "application/json",
      },
      timeoutMs: 15000,
    })
  }

  function fetchSubscriptions(ctx, apiKey) {
    return ctx.util.requestJson({
      method: "GET",
      url: SUBS_URL,
      headers: {
        "Authorization": "Bearer " + apiKey,
        "Content-Type": "application/json",
      },
      timeoutMs: 15000,
    })
  }

  function formatPlanLabel(planId) {
    return PLAN_LABELS[planId] || planId.split("-").map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
  }

  async function probe(ctx) {
    var apiKey = loadApiKey(ctx)
    if (!apiKey) {
      throw "CommandCode not installed. Install CommandCode to get started."
    }

    var result
    try {
      result = fetchCredits(ctx, apiKey)
    } catch (e) {
      ctx.host.log.error("credits request failed: " + String(e))
      throw "Request failed. Check your connection."
    }

    var resp = result.resp
    var json = result.json

    if (resp.status === 401 || resp.status === 403) {
      throw "Session expired. Re-authenticate in CommandCode."
    }
    if (resp.status < 200 || resp.status >= 300) {
      var detail = json && json.error && json.error.message ? json.error.message : ""
      if (detail) {
        ctx.host.log.error("api returned " + resp.status + ": " + detail)
        throw detail
      }
      ctx.host.log.error("api returned: " + resp.status)
      throw "Request failed (HTTP " + resp.status + "). Try again later."
    }

    if (!json || !json.credits || typeof json.credits.monthlyCredits !== "number") {
      ctx.host.log.error("unexpected credits response structure")
      throw "Could not parse usage data."
    }

    var remaining = json.credits.monthlyCredits

    var subResult
    try {
      subResult = await fetchSubscriptions(ctx, apiKey)
    } catch (e) {
      ctx.host.log.error("subscription request failed: " + String(e))
      throw "Request failed. Check your connection."
    }

    var subResp = subResult.resp
    var subJson = subResult.json

    if (subResp.status === 401 || subResp.status === 403) {
      throw "Session expired. Re-authenticate in CommandCode."
    }
    if (subResp.status < 200 || subResp.status >= 300) {
      var detail = subJson && subJson.error && subJson.error.message ? subJson.error.message : ""
      if (detail) {
        ctx.host.log.error("api returned " + subResp.status + ": " + detail)
        throw detail
      }
      ctx.host.log.error("api returned: " + subResp.status)
      throw "Request failed (HTTP " + subResp.status + "). Try again later."
    }

    if (!subJson || !subJson.success || !subJson.data) {
      ctx.host.log.error("unexpected subscription response structure")
      throw "Could not parse subscription data."
    }

    var planId = subJson.data.planId
    var total = PLAN_LIMITS[planId] || 0
    var used = Math.max(0, total - remaining)

    var resetsAtMs = new Date(subJson.data.currentPeriodEnd).getTime()

    var lines = []
    if (planId && total > 0) {
      lines.push(ctx.line.progress({
        label: "Monthly Quota",
        used: Math.min(100, Math.max(0, Math.round((used / total) * 100))),
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(resetsAtMs),
        periodDurationMs: 30 * 24 * 3600 * 1000,
      }))
      lines.push(ctx.line.progress({
        label: formatPlanLabel(planId),
        used: used,
        limit: total,
        format: { kind: "dollars" },
        resetsAt: ctx.util.toIso(resetsAtMs),
        periodDurationMs: 30 * 24 * 3600 * 1000,
      }))
    }

    return { plan: planId, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "command-code", probe: probe }
})()
