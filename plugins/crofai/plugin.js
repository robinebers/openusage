(function () {
  var API_URL = "https://crof.ai/usage_api/"

  function probe(ctx) {
    var apiKey = ctx.host.env.get("CROFAI_API_KEY")
    if (!apiKey || !String(apiKey).trim()) {
      throw "No CROFAI_API_KEY found. Set up environment variable first."
    }

    var resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: API_URL,
        headers: {
          Authorization: "Bearer " + String(apiKey).trim(),
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "API key invalid. Check your CrofAI API key."
    }

    if (resp.status < 200 || resp.status >= 300) {
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    var data = ctx.util.tryParseJson(resp.bodyText)
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw "Usage response invalid. Try again later."
    }

    var hasCredits = typeof data.credits === "number" && Number.isFinite(data.credits)
    if ("credits" in data && !hasCredits) {
      throw "Usage response invalid. Try again later."
    }
    var credits = hasCredits ? data.credits : 0

    var lines = []

    var usableRequests = data.usable_requests
    if (usableRequests !== null && usableRequests !== undefined) {
      if (typeof usableRequests !== "number" || !Number.isFinite(usableRequests)) {
        throw "Usage response invalid. Try again later."
      }

      var requestsPlan = data.requests_plan
      if (typeof requestsPlan !== "number" || !Number.isFinite(requestsPlan) || requestsPlan <= 0) {
        throw "Usage response invalid. Try again later."
      }

      var usedRequests = Math.max(0, requestsPlan - usableRequests)
      lines.push(
        ctx.line.progress({
          label: "Requests",
          used: usedRequests,
          limit: requestsPlan,
          format: { kind: "count", suffix: "requests" },
        })
      )
    }

    if (hasCredits && credits >= 0) {
      lines.push(
        ctx.line.text({
          label: "Credits",
          value: "$" + credits.toFixed(2),
        })
      )
    }

    return { lines: lines }
  }

  globalThis.__openusage_plugin = { id: "crofai", probe }
})()
