(function () {
  const AUTH_FILE = "~/.commandcode/auth.json"
  const API_BASE = "https://api.commandcode.ai"
  const ERR_NOT_LOGGED_IN = "Not logged in. Run `cmd login` to authenticate."

  // Plan name mapping: planId -> human label
  var PLAN_LABELS = {
    "individual-go": "Individual Go",
    "individual": "Individual",
    "pro": "Pro",
    "team": "Team",
    "enterprise": "Enterprise",
  }

  function readNumber(value) {
    var n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function loadApiKeyFromEnv(ctx) {
    try {
      var value = ctx.host.env.get("COMMAND_CODE_API_KEY")
      if (typeof value !== "string") return null
      var trimmed = value.trim()
      return trimmed || null
    } catch (e) {
      ctx.host.log.warn("COMMAND_CODE_API_KEY read failed: " + String(e))
      return null
    }
  }

  function loadApiKeyFromFile(ctx) {
    if (!ctx.host.fs.exists(AUTH_FILE)) return null
    try {
      var text = ctx.host.fs.readText(AUTH_FILE)
      var parsed = ctx.util.tryParseJson(text)
      if (!parsed || typeof parsed !== "object") return null
      var key = typeof parsed.apiKey === "string" ? parsed.apiKey.trim() : null
      return key || null
    } catch (e) {
      ctx.host.log.warn("auth file read failed: " + String(e))
      return null
    }
  }

  function loadApiKey(ctx) {
    return loadApiKeyFromEnv(ctx) || loadApiKeyFromFile(ctx)
  }

  function apiCall(ctx, method, url, apiKey) {
    try {
      var resp = ctx.host.http.request({
        method: method,
        url: url,
        headers: {
          Authorization: "Bearer " + apiKey,
          "Content-Type": "application/json",
          Accept: "application/json",
          "User-Agent": "OpenUsage",
        },
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("API call failed: " + url + " status=" + resp.status)
        return null
      }
      var parsed = ctx.util.tryParseJson(resp.bodyText)
      if (!parsed) {
        ctx.host.log.warn("API response not valid JSON: " + url)
        return null
      }
      return parsed
    } catch (e) {
      ctx.host.log.error("API call exception: " + url + " " + String(e))
      return null
    }
  }

  function probe(ctx) {
    var apiKey = loadApiKey(ctx)
    if (!apiKey) {
      ctx.host.log.error("probe failed: no api key in auth file or COMMAND_CODE_API_KEY env var")
      throw ERR_NOT_LOGGED_IN
    }

    ctx.host.log.info("loaded api key")

    // Fetch whoami (no orgId param needed for personal accounts)
    var whoami = apiCall(ctx, "GET", API_BASE + "/alpha/whoami", apiKey)
    if (!whoami) {
      throw "Command Code API unreachable. Check your connection."
    }

    // Fetch credits (plan limit) and usage summary in parallel
    var creditsResp = apiCall(ctx, "GET", API_BASE + "/alpha/billing/credits", apiKey)
    var usageResp = apiCall(ctx, "GET", API_BASE + "/alpha/usage/summary", apiKey)

    // Fetch subscription for plan info
    var subResp = apiCall(ctx, "GET", API_BASE + "/alpha/billing/subscriptions", apiKey)

    // -- Parse credits (remaining balance) --
    // credits.credits.monthlyCredits = remaining balance (e.g. $6.59)
    var creditsRemaining = null
    if (creditsResp && creditsResp.credits && typeof creditsResp.credits === "object") {
      creditsRemaining = readNumber(creditsResp.credits.monthlyCredits)
    }

    // -- Parse usage summary --
    // usage summary has fields at the root: totalCost, totalMonthlyCredits, models, etc.
    // totalMonthlyCredits = amount used this month (e.g. $3.41)
    // Total plan = remaining + used
    var totalCost = null
    var monthlyUsed = null
    var totalTokens = null
    var models = []

    if (usageResp && typeof usageResp === "object") {
      totalCost = readNumber(usageResp.totalCost)
      monthlyUsed = readNumber(usageResp.totalMonthlyCredits)
      totalTokens = readNumber(usageResp.totalTokens)

      if (Array.isArray(usageResp.models)) {
        models = usageResp.models
      }
    }

    // -- Parse plan name from subscription --
    var planLabel = null
    if (subResp && subResp.success && subResp.data && typeof subResp.data.planId === "string") {
      var planId = subResp.data.planId
      planLabel = PLAN_LABELS[planId] || ctx.fmt.planLabel(planId)
    }

    var lines = []

    // -- Progress bar: Monthly credits used vs total plan --
    // total plan = used + remaining
    if (creditsRemaining !== null && monthlyUsed !== null) {
      var totalPlan = monthlyUsed + Math.max(0, creditsRemaining)
      var usedPercent = totalPlan > 0 ? (monthlyUsed / totalPlan) * 100 : 100
      if (usedPercent > 100) usedPercent = 100
      if (usedPercent < 0) usedPercent = 0

      lines.push(ctx.line.progress({
        label: "Monthly credits",
        used: Math.round(usedPercent * 10) / 10,
        limit: 100,
        format: { kind: "percent" },
        periodDurationMs: 30 * 24 * 60 * 60 * 1000,
      }))
    }

    // -- Text: Total cost spent --
    if (totalCost !== null && totalCost > 0) {
      lines.push(ctx.line.text({
        label: "Total spent",
        value: "$" + totalCost.toFixed(2),
      }))
    }

    // -- Text: Token usage --
    if (totalTokens !== null && totalTokens > 0) {
      lines.push(ctx.line.text({
        label: "Tokens used",
        value: fmtTokens(Math.round(totalTokens)),
      }))
    }

    // -- Model breakdown (detail) --
    if (models.length > 0) {
      var totalModelCost = 0
      var modelParts = []
      for (var i = 0; i < models.length; i++) {
        var m = models[i]
        if (!m || typeof m !== "object") continue
        var name = m.model || m.name
        if (typeof name !== "string" || !name.trim()) continue

        var cost = readNumber(m.totalCost) || 0
        var count = readNumber(m.count) || 0
        totalModelCost += cost

        // Shorten model names for display
        var shortName = name
        var slashIdx = name.indexOf("/")
        if (slashIdx !== -1) shortName = name.slice(slashIdx + 1)

        var detail = shortName
        if (cost > 0) detail += " $" + cost.toFixed(2)
        if (count > 0) detail += " (" + count + " calls)"
        modelParts.push(detail)
      }

      if (modelParts.length > 0) {
        lines.push(ctx.line.text({
          label: "Models",
          value: modelParts.join("  "),
        }))
      }
    }

    return { plan: planLabel, lines: lines }
  }

  function fmtTokens(n) {
    var abs = Math.abs(n)
    var sign = n < 0 ? "-" : ""
    var units = [
      { threshold: 1e9, divisor: 1e9, suffix: "B" },
      { threshold: 1e6, divisor: 1e6, suffix: "M" },
      { threshold: 1e3, divisor: 1e3, suffix: "K" },
    ]
    for (var i = 0; i < units.length; i++) {
      var unit = units[i]
      if (abs >= unit.threshold) {
        var scaled = abs / unit.divisor
        var formatted = scaled >= 10
          ? Math.round(scaled).toString()
          : scaled.toFixed(1).replace(/\.0$/, "")
        return sign + formatted + unit.suffix
      }
    }
    return sign + Math.round(abs).toString()
  }

  globalThis.__openusage_plugin = { id: "command-code", probe: probe }
})()
