(function () {
  function probe(ctx) {
    // Read the data from user defaults
    let json
    try {
      json = ctx.host.defaults.read("dev.warp.Warp-Stable", "AIRequestLimitInfo")
    } catch (e) {
      ctx.host.log.info("Warp: AIRequestLimitInfo key not found in preferences: " + String(e))
      throw "No Warp AI usage data found. Ensure Warp is installed and you have used AI at least once. If you have, this may be a plugin bug."
    }

    // Parse and validate the data structure
    const data = ctx.util.tryParseJson(json)
    if (!data || typeof data !== "object") {
      ctx.host.log.error("Warp: Malformed quota data: " + json)
      throw "Warp AI quota data is malformed. This may be a plugin bug."
    }

    const { num_requests_used_since_refresh: used, limit, next_refresh_time: resetsAt } = data

    if (
      !Number.isFinite(used) ||
      !Number.isFinite(limit) ||
      limit <= 0 ||
      !resetsAt ||
      !Number.isFinite(new Date(resetsAt).getTime())
    ) {
      ctx.host.log.error("Warp: Incomplete quota data: " + json)
      throw "Warp AI quota data is malformed. This may be a plugin bug."
    }

    // Staleness check: Ensure the data belongs to an active cycle
    if (new Date(resetsAt) < new Date(ctx.nowIso)) {
      ctx.host.log.info("Warp: Quota data is stale (expired " + resetsAt + ")")
      throw "No active Warp AI quota found. Have your credits reset recently? Try using Warp AI once to refresh it."
    }

    // Return the formatted usage lines
    return {
      lines: [
        ctx.line.progress({
          label: "AI Credits",
          used,
          limit,
          format: { kind: "count", suffix: "credits" },
          resetsAt: ctx.util.toIso(resetsAt),
        }),
      ],
    }
  }

  globalThis.__openusage_plugin = { id: "warp", probe }
})()
