(function () {
  var API_KEY_ENV_VARS = ["NEURALWATT_API_KEY"]
  var QUOTA_URL = "https://api.neuralwatt.com/v1/quota"

  function readNumber(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value === "string") {
      var parsed = Number(value)
      return Number.isFinite(parsed) ? parsed : null
    }
    return null
  }

  function readString(value) {
    if (typeof value !== "string") return null
    var trimmed = value.trim()
    return trimmed || null
  }

  function parseDateMs(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value === "string") {
      var parsed = Date.parse(value)
      return Number.isFinite(parsed) ? parsed : null
    }
    return null
  }

  function parseSubscriptionPeriodMs(sub) {
    if (!sub || !sub.current_period_start || !sub.current_period_end) return null
    var startMs = parseDateMs(sub.current_period_start)
    var endMs = parseDateMs(sub.current_period_end)
    if (startMs !== null && endMs !== null && endMs > startMs) return endMs - startMs
    return null
  }

  function loadApiKey(ctx) {
    for (var i = 0; i < API_KEY_ENV_VARS.length; i += 1) {
      var name = API_KEY_ENV_VARS[i]
      var value = null
      try {
        value = ctx.host.env.get(name)
      } catch (e) {
        ctx.host.log.warn("env read failed for " + name + ": " + String(e))
      }
      if (value && typeof value === "string" && value.trim()) {
        ctx.host.log.info("api key loaded from " + name)
        return { value: value.trim(), source: name }
      }
    }
    return null
  }

  function probe(ctx) {
    var apiKeyInfo = loadApiKey(ctx)
    if (!apiKeyInfo) {
      throw "Neuralwatt API key missing. Set NEURALWATT_API_KEY."
    }

    var resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: QUOTA_URL,
        headers: {
          Authorization: "Bearer " + apiKeyInfo.value,
          Accept: "application/json",
          "User-Agent": "OpenUsage",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      throw "Request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Invalid API key. Check NEURALWATT_API_KEY."
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw "Request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    var data = ctx.util.tryParseJson(resp.bodyText)
    if (!data || typeof data !== "object") {
      throw "Response invalid. Try again later."
    }

    var sub = data.subscription && typeof data.subscription === "object" ? data.subscription : null
    var balance = data.balance && typeof data.balance === "object" ? data.balance : null
    var plan = null
    var resetsAt = null
    var periodDurationMs = null

    if (sub) {
      if (typeof sub.plan === "string" && sub.plan) {
        plan = sub.plan.charAt(0).toUpperCase() + sub.plan.slice(1)
      }
      if (sub.current_period_end) {
        var endMs = parseDateMs(sub.current_period_end)
        resetsAt = endMs !== null ? ctx.util.toIso(endMs) : null
      }
      periodDurationMs = parseSubscriptionPeriodMs(sub)
    }

    var lines = []

    // Subscription energy line (hidden if no subscription)
    if (sub) {
      var kwhIncluded = readNumber(sub.kwh_included)
      var kwhUsed = readNumber(sub.kwh_used)
      if (kwhIncluded !== null && kwhIncluded > 0 && kwhUsed !== null) {
        var energyLine = {
          label: "Subscription",
          used: Math.round(kwhUsed * 10000) / 10000,
          limit: Math.round(kwhIncluded * 10000) / 10000,
          format: { kind: "count", suffix: "kWh" },
        }
        if (resetsAt) energyLine.resetsAt = resetsAt
        if (periodDurationMs) energyLine.periodDurationMs = periodDurationMs
        lines.push(ctx.line.progress(energyLine))
      }
    }

    // Balance line (hidden if total credits is 0)
    if (balance) {
      var totalCredits = readNumber(balance.total_credits_usd)
      var usedCredits = readNumber(balance.credits_used_usd)
      if (totalCredits !== null && totalCredits > 0 && usedCredits !== null) {
        lines.push(ctx.line.progress({
          label: "Balance",
          used: Math.round(usedCredits * 100) / 100,
          limit: Math.round(totalCredits * 100) / 100,
          format: { kind: "dollars" },
        }))
      }

      // Accounting method badge
      var method = readString(balance.accounting_method)
      if (method) {
        lines.push(ctx.line.badge({ label: "Method", text: method.charAt(0).toUpperCase() + method.slice(1) }))
      }
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "neuralwatt", probe: probe }
})()
