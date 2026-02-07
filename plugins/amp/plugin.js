(function () {
  var SECRETS_FILE = "~/.local/share/amp/secrets.json"
  var SECRETS_KEY = "apiKey@https://ampcode.com/"
  var API_URL = "https://ampcode.com/api/internal"

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

  function fetchBalanceInfo(ctx, apiKey) {
    return ctx.util.requestJson({
      method: "POST",
      url: API_URL,
      headers: {
        "Authorization": "Bearer " + apiKey,
        "Content-Type": "application/json",
      },
      bodyText: JSON.stringify({ method: "userDisplayBalanceInfo", params: {} }),
      timeoutMs: 15000,
    })
  }

  function parseBalanceText(text) {
    if (!text || typeof text !== "string") return null

    var result = {
      remaining: null,
      total: null,
      hourlyRate: 0,
      bonusPct: null,
      bonusDays: null,
      credits: null,
    }

    var balanceMatch = text.match(/\$([0-9]+(?:\.[0-9]+)?)\/\$([0-9]+(?:\.[0-9]+)?) remaining/)
    if (balanceMatch) {
      var remaining = Number(balanceMatch[1])
      var total = Number(balanceMatch[2])
      if (Number.isFinite(remaining) && Number.isFinite(total)) {
        result.remaining = remaining
        result.total = total
      }
    }

    var rateMatch = text.match(/replenishes \+\$([0-9]+(?:\.[0-9]+)?)\/hour/)
    if (rateMatch) result.hourlyRate = Number(rateMatch[1])

    var bonusMatch = text.match(/\+(\d+)% bonus for (\d+) more days?/)
    if (bonusMatch) {
      result.bonusPct = Number(bonusMatch[1])
      result.bonusDays = Number(bonusMatch[2])
    }

    var creditsMatch = text.match(/Individual credits: \$([0-9]+(?:\.[0-9]+)?) remaining/)
    if (creditsMatch) {
      result.credits = Number(creditsMatch[1])
    }

    if (result.total === null && result.credits === null) return null

    return result
  }

  function probe(ctx) {
    var apiKey = loadApiKey(ctx)
    if (!apiKey) {
      throw "Amp not installed. Install Amp Code to get started."
    }

    var result
    try {
      result = fetchBalanceInfo(ctx, apiKey)
    } catch (e) {
      ctx.host.log.error("balance info request failed: " + String(e))
      throw "Request failed. Check your connection."
    }

    var resp = result.resp
    var json = result.json

    if (resp.status === 401 || resp.status === 403) {
      throw "Session expired. Re-authenticate in Amp Code."
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

    if (!json || !json.ok || !json.result || !json.result.displayText) {
      ctx.host.log.error("unexpected response structure")
      throw "Could not parse usage data."
    }

    var balance = parseBalanceText(json.result.displayText)
    if (!balance) {
      ctx.host.log.error("failed to parse display text: " + json.result.displayText)
      throw "Could not parse usage data."
    }

    var lines = []
    var plan = "Free"

    if (balance.total !== null) {
      var used = Math.max(0, balance.total - balance.remaining)
      var total = balance.total

      var resetsAtMs = null
      if (used > 0 && balance.hourlyRate > 0) {
        var hoursToFull = used / balance.hourlyRate
        resetsAtMs = Date.now() + hoursToFull * 3600 * 1000
      }

      lines.push(ctx.line.progress({
        label: "Free",
        used: used,
        limit: total,
        format: { kind: "dollars" },
        resetsAt: ctx.util.toIso(resetsAtMs),
        periodDurationMs: 24 * 3600 * 1000,
      }))

      if (balance.bonusPct && balance.bonusDays) {
        lines.push(ctx.line.text({
          label: "Bonus",
          value: "+" + balance.bonusPct + "% for " + balance.bonusDays + "d",
        }))
      }
    }

    if (balance.credits !== null && balance.credits > 0) {
      lines.push(ctx.line.text({
        label: "Credits",
        value: "$" + balance.credits.toFixed(2),
      }))
      if (balance.total === null) plan = "Credits"
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "amp", probe: probe }
})()
