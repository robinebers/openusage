(function () {
  const KEY_URL = "https://openrouter.ai/api/v1/key"
  const CREDITS_URL = "https://openrouter.ai/api/v1/credits"

  function loadApiKey(ctx) {
    const apiKey = ctx.host.env.get("OPENROUTER_API_KEY")
    if (typeof apiKey === "string" && apiKey.trim()) return apiKey.trim()
    return null
  }

  function readNumber(value) {
    if (value === null || value === undefined) return null
    if (typeof value === "string" && !value.trim()) return null
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function formatUsd(amount) {
    const rounded = Math.round(Math.max(0, amount) * 100) / 100
    return "$" + rounded.toFixed(2)
  }

  function trimString(value) {
    if (typeof value !== "string") return null
    const trimmed = value.trim()
    return trimmed ? trimmed : null
  }

  function fetchKeyInfo(ctx, apiKey) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: KEY_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      ctx.host.log.error("key request exception: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "API key invalid. Check your OpenRouter API key."
    }

    if (resp.status < 200 || resp.status >= 300) {
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    const parsed = ctx.util.tryParseJson(resp.bodyText)
    if (!parsed || typeof parsed !== "object" || !parsed.data || typeof parsed.data !== "object") {
      throw "Usage response invalid. Try again later."
    }

    return parsed.data
  }

  function fetchCredits(ctx, apiKey) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: CREDITS_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      ctx.host.log.warn("credits request exception: " + String(e))
      return null
    }

    if (ctx.util.isAuthStatus(resp.status)) return null
    if (resp.status < 200 || resp.status >= 300) return null

    const parsed = ctx.util.tryParseJson(resp.bodyText)
    if (!parsed || typeof parsed !== "object" || !parsed.data || typeof parsed.data !== "object") {
      return null
    }

    return parsed.data
  }

  function buildPlanLabel(data) {
    if (data.is_free_tier === true) return "Free"
    return "Paid"
  }

  function pushMoneyLine(ctx, lines, label, amount, suffix) {
    if (amount === null) return
    lines.push(ctx.line.text({ label: label, value: formatUsd(amount) + suffix }))
  }

  function probe(ctx) {
    const apiKey = loadApiKey(ctx)
    if (!apiKey) {
      throw "No OPENROUTER_API_KEY found. Set up environment variable first."
    }

    const data = fetchKeyInfo(ctx, apiKey)
    const lines = []

    const limit = readNumber(data.limit)
    const remaining = readNumber(data.limit_remaining)
    const usage = readNumber(data.usage)
    const daily = readNumber(data.usage_daily)
    const weekly = readNumber(data.usage_weekly)
    const monthly = readNumber(data.usage_monthly)
    const credits = fetchCredits(ctx, apiKey)
    const totalCredits = credits ? readNumber(credits.total_credits) : null
    const totalUsage = credits ? readNumber(credits.total_usage) : null
    const accountCreditsRemaining =
      totalCredits !== null && totalUsage !== null ? Math.max(0, totalCredits - totalUsage) : null
    const keyCreditsRemaining =
      remaining !== null ? Math.max(0, remaining) : limit !== null && usage !== null ? Math.max(0, limit - usage) : null

    if (accountCreditsRemaining !== null) {
      lines.push(ctx.line.text({ label: "Credits", value: formatUsd(accountCreditsRemaining) + " left" }))
    } else if (keyCreditsRemaining !== null) {
      lines.push(ctx.line.text({ label: "Credits", value: formatUsd(keyCreditsRemaining) + " left" }))
    } else {
      lines.push(ctx.line.text({ label: "Credits", value: "No key limit" }))
    }

    pushMoneyLine(ctx, lines, "This Month", monthly, "")
    pushMoneyLine(ctx, lines, "All Time", totalUsage !== null ? totalUsage : usage, "")

    const plan = buildPlanLabel(data)
    return plan ? { plan: plan, lines: lines } : { lines: lines }
  }

  globalThis.__openusage_plugin = { id: "openrouter", probe: probe }
})()
