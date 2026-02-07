(function () {
  var LS_SERVICE = "exa.language_server_pb.LanguageServerService"
  var STATE_DB = "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"

  // --- LS discovery ---

  function discoverLs(ctx) {
    return ctx.host.ls.discover({
      processName: "language_server_macos",
      markers: ["windsurf"],
      csrfFlag: "--csrf_token",
      portFlag: "--extension_server_port",
      extraFlags: ["--windsurf_version"],
    })
  }

  function loadApiKey(ctx) {
    try {
      var rows = ctx.host.sqlite.query(
        STATE_DB,
        "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1"
      )
      var parsed = ctx.util.tryParseJson(rows)
      if (!parsed || !parsed.length || !parsed[0].value) return null
      var auth = ctx.util.tryParseJson(parsed[0].value)
      if (!auth || !auth.apiKey) return null
      return auth.apiKey
    } catch (e) {
      ctx.host.log.warn("failed to read API key: " + String(e))
      return null
    }
  }

  function probePort(ctx, scheme, port, csrf) {
    ctx.host.http.request({
      method: "POST",
      url: scheme + "://127.0.0.1:" + port + "/" + LS_SERVICE + "/GetUnleashData",
      headers: {
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
        "x-codeium-csrf-token": csrf,
      },
      bodyText: JSON.stringify({
        context: {
          properties: {
            devMode: "false",
            extensionVersion: "unknown",
            ide: "windsurf",
            ideVersion: "unknown",
            os: "macos",
          },
        },
      }),
      timeoutMs: 5000,
      dangerouslyIgnoreTls: scheme === "https",
    })
    return true
  }

  function findWorkingPort(ctx, discovery) {
    var ports = discovery.ports || []
    for (var i = 0; i < ports.length; i++) {
      var port = ports[i]
      try { if (probePort(ctx, "https", port, discovery.csrf)) return { port: port, scheme: "https" } } catch (e) { /* ignore */ }
      try { if (probePort(ctx, "http", port, discovery.csrf)) return { port: port, scheme: "http" } } catch (e) { /* ignore */ }
      ctx.host.log.info("port " + port + " probe failed on both schemes")
    }
    if (discovery.extensionPort) return { port: discovery.extensionPort, scheme: "http" }
    return null
  }

  function callLs(ctx, port, scheme, csrf, method, body) {
    var resp = ctx.host.http.request({
      method: "POST",
      url: scheme + "://127.0.0.1:" + port + "/" + LS_SERVICE + "/" + method,
      headers: {
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
        "x-codeium-csrf-token": csrf,
      },
      bodyText: JSON.stringify(body || {}),
      timeoutMs: 10000,
      dangerouslyIgnoreTls: scheme === "https",
    })
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("callLs " + method + " returned " + resp.status)
      return null
    }
    return ctx.util.tryParseJson(resp.bodyText)
  }

  // --- Credit line builder ---

  function creditLine(ctx, label, used, total, resetsAt, periodMs) {
    if (typeof total !== "number" || total <= 0) return null
    if (typeof used !== "number") used = 0
    if (used < 0) used = 0
    var line = {
      label: label,
      used: used,
      limit: total,
      format: { kind: "count", suffix: "credits" },
    }
    if (resetsAt) line.resetsAt = resetsAt
    if (periodMs) line.periodDurationMs = periodMs
    return ctx.line.progress(line)
  }

  // --- LS probe ---

  function probeViaLs(ctx) {
    var discovery = discoverLs(ctx)
    if (!discovery) return null

    var found = findWorkingPort(ctx, discovery)
    if (!found) return null

    var apiKey = loadApiKey(ctx)
    if (!apiKey) {
      ctx.host.log.warn("no API key found in SQLite")
      return null
    }

    var version = (discovery.extra && discovery.extra.windsurf_version) || "unknown"

    var metadata = {
      apiKey: apiKey,
      ideName: "windsurf",
      ideVersion: version,
      extensionName: "windsurf",
      extensionVersion: version,
      locale: "en",
    }

    var data = null
    try {
      data = callLs(ctx, found.port, found.scheme, discovery.csrf, "GetUserStatus", { metadata: metadata })
    } catch (e) {
      ctx.host.log.warn("GetUserStatus threw: " + String(e))
    }

    if (!data || !data.userStatus) return null

    var us = data.userStatus
    var ps = us.planStatus || {}
    var pi = ps.planInfo || {}

    var plan = pi.planName || null

    // Billing cycle for pacing
    var planEnd = ps.planEnd || null
    var planStart = ps.planStart || null
    var periodMs = null
    if (planStart && planEnd) {
      var startMs = Date.parse(planStart)
      var endMs = Date.parse(planEnd)
      if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) {
        periodMs = endMs - startMs
      }
    }

    var lines = []

    // API returns credits in hundredths (like cents) — divide by 100 for display
    // Windsurf UI: "0/500 prompt credits" = API availablePromptCredits: 50000

    // Prompt credits
    var promptTotal = ps.availablePromptCredits
    var promptUsed = ps.usedPromptCredits || 0
    if (typeof promptTotal === "number" && promptTotal > 0) {
      var pl = creditLine(ctx, "Prompt credits", promptUsed / 100, promptTotal / 100, planEnd, periodMs)
      if (pl) lines.push(pl)
    }

    // Flex credits
    var flexTotal = ps.availableFlexCredits
    var flexUsed = ps.usedFlexCredits || 0
    if (typeof flexTotal === "number" && flexTotal > 0) {
      var xl = creditLine(ctx, "Flex credits", flexUsed / 100, flexTotal / 100, planEnd, periodMs)
      if (xl) lines.push(xl)
    }

    if (lines.length === 0) {
      // All credits unlimited (negative available) — still return plan, show badge
      lines.push(ctx.line.badge({ label: "Credits", text: "Unlimited" }))
    }

    return { plan: plan, lines: lines }
  }

  // --- Probe ---

  function probe(ctx) {
    var result = probeViaLs(ctx)
    if (result) return result

    throw "Start Windsurf and try again."
  }

  globalThis.__openusage_plugin = { id: "windsurf", probe: probe }
})()
