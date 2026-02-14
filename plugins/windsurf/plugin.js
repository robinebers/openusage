(function () {
  var LS_SERVICE = "exa.language_server_pb.LanguageServerService"
  var MAC_STATE_DB = "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
  var LINUX_STATE_DB = "~/.config/Windsurf/User/globalStorage/state.vscdb"

  // Windsurf variants — tried in order (Windsurf first, then Windsurf Next).
  // Markers use --ide_name exact matching in the Rust discover code.
  var VARIANTS = [
    {
      marker: "windsurf",
      ideName: "windsurf",
      stateDb: "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
    },
    {
      marker: "windsurf-next",
      ideName: "windsurf-next",
      stateDb: "~/Library/Application Support/Windsurf - Next/User/globalStorage/state.vscdb",
    },
  ]

  function joinPath(base, leaf, separator) {
    if (!base) return leaf
    if (base.endsWith("/") || base.endsWith("\\")) return base + leaf
    return base + separator + leaf
  }

  function getStateDbPath(ctx) {
    if (ctx.app.platform === "windows") {
      var candidates = [
        "~/AppData/Roaming/Windsurf/User",
        "~/AppData/Local/Windsurf/User",
      ]
      for (var i = 0; i < candidates.length; i++) {
        var dbPath = joinPath(candidates[i], "globalStorage/state.vscdb", "/")
        if (ctx.host.fs.exists(dbPath)) return dbPath
      }
      if (candidates.length > 0) {
        return joinPath(candidates[0], "globalStorage/state.vscdb", "/")
      }
      return null
    }

    if (ctx.app.platform === "linux") return LINUX_STATE_DB
    return MAC_STATE_DB
  }

  // --- LS discovery ---

  function discoverLs(ctx, variant) {
    var processName = ctx.app.platform === "windows"
      ? "language_server_windows_x64.exe"
      : (ctx.app.platform === "linux" ? "language_server_linux_x64" : "language_server_macos")
    
    return ctx.host.ls.discover({
      processName: processName,
      markers: [variant.marker],
      csrfFlag: "--csrf_token",
      portFlag: "--extension_server_port",
      extraFlags: ["--windsurf_version"],
    })
  }

  function loadApiKey(ctx, variant) {
    try {
      var stateDb = ctx.app.platform === "windows" ? getStateDbPath(ctx) : variant.stateDb
      if (!stateDb) {
        ctx.host.log.warn("state db path not found for Windsurf")
        return null
      }
      var rows = ctx.host.sqlite.query(
        stateDb,
        "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1"
      )
      var parsed = ctx.util.tryParseJson(rows)
      if (!parsed || !parsed.length || !parsed[0].value) return null
      var auth = ctx.util.tryParseJson(parsed[0].value)
      if (!auth || !auth.apiKey) return null
      return auth.apiKey
    } catch (e) {
      ctx.host.log.warn("failed to read API key from " + variant.marker + ": " + String(e))
      return null
    }
  }

  function probePort(ctx, scheme, port, csrf, ideName) {
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
            ide: ideName,
            ideVersion: "unknown",
            os: ctx.app.platform === "windows" ? "windows" : (ctx.app.platform === "linux" ? "linux" : "macos"),
          },
        },
      }),
      timeoutMs: 5000,
      dangerouslyIgnoreTls: scheme === "https",
    })
    return true
  }

  function findWorkingPort(ctx, discovery, ideName) {
    var ports = discovery.ports || []
    for (var i = 0; i < ports.length; i++) {
      var port = ports[i]
      try { if (probePort(ctx, "https", port, discovery.csrf, ideName)) return { port: port, scheme: "https" } } catch (e) { /* ignore */ }
      try { if (probePort(ctx, "http", port, discovery.csrf, ideName)) return { port: port, scheme: "http" } } catch (e) { /* ignore */ }
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

  // --- LS probe for a specific variant ---

  function probeVariant(ctx, variant) {
    var discovery = discoverLs(ctx, variant)
    if (!discovery) return null

    var found = findWorkingPort(ctx, discovery, variant.ideName)
    if (!found) return null

    var apiKey = loadApiKey(ctx, variant)
    if (!apiKey) {
      ctx.host.log.warn("no API key found in SQLite for " + variant.marker)
      return null
    }

    var version = (discovery.extra && discovery.extra.windsurf_version) || "unknown"

    var metadata = {
      apiKey: apiKey,
      ideName: variant.ideName,
      ideVersion: version,
      extensionName: variant.ideName,
      extensionVersion: version,
      locale: "en",
    }

    var data = null
    try {
      data = callLs(ctx, found.port, found.scheme, discovery.csrf, "GetUserStatus", { metadata: metadata })
    } catch (e) {
      ctx.host.log.warn("GetUserStatus threw for " + variant.marker + ": " + String(e))
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
      var xl = creditLine(ctx, "Flex credits", flexUsed / 100, flexTotal / 100, null, null)
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
    if (ctx.app.platform === "windows") {
      var stateDb = getStateDbPath(ctx)
      if (!stateDb || !ctx.host.fs.exists(stateDb)) {
        throw "Windsurf data store not found on Windows. Expected %APPDATA%\\Windsurf\\User\\globalStorage\\state.vscdb (or Local). Please report the actual path."
      }
    }
    // Try each variant in order: Windsurf → Windsurf Next
    for (var i = 0; i < VARIANTS.length; i++) {
      var result = probeVariant(ctx, VARIANTS[i])
      if (result) return result
    }

    throw "Start Windsurf and try again."
  }

  globalThis.__openusage_plugin = { id: "windsurf", probe: probe }
})()
