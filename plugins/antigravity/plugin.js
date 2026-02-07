(function () {
  var LS_SERVICE = "exa.language_server_pb.LanguageServerService"

  // --- LS discovery ---

  function discoverLs(ctx) {
    return ctx.host.ls.discover({
      processName: "language_server_macos",
      markers: ["antigravity"],
      csrfFlag: "--csrf_token",
      portFlag: "--extension_server_port",
    })
  }

  function findWorkingPort(ctx, discovery) {
    var ports = discovery.ports || []
    for (var i = 0; i < ports.length; i++) {
      var port = ports[i]
      try {
        var resp = ctx.host.http.request({
          method: "POST",
          url: "http://127.0.0.1:" + port + "/" + LS_SERVICE + "/GetUnleashData",
          headers: {
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "x-codeium-csrf-token": discovery.csrf,
          },
          bodyText: JSON.stringify({
            context: {
              properties: {
                devMode: "false",
                extensionVersion: "unknown",
                ide: "antigravity",
                ideVersion: "unknown",
                os: "macos",
              },
            },
          }),
          timeoutMs: 5000,
        })
        if (resp.status === 200) return port
      } catch (e) {
        ctx.host.log.info("port " + port + " probe failed: " + String(e))
      }
    }
    // Try extension port as HTTP fallback
    if (discovery.extensionPort) return discovery.extensionPort
    return null
  }

  function callLs(ctx, port, csrf, method, body) {
    var resp = ctx.host.http.request({
      method: "POST",
      url: "http://127.0.0.1:" + port + "/" + LS_SERVICE + "/" + method,
      headers: {
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
        "x-codeium-csrf-token": csrf,
      },
      bodyText: JSON.stringify(body || {}),
      timeoutMs: 10000,
    })
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("callLs " + method + " returned " + resp.status)
      return null
    }
    return ctx.util.tryParseJson(resp.bodyText)
  }

  // --- Line builders ---

  function normalizeLabel(label) {
    // "Gemini 3 Pro (High)" -> "Gemini 3 Pro"
    return label.replace(/\s*\([^)]*\)\s*$/, "").trim()
  }

  function modelSortKey(label) {
    var lower = label.toLowerCase()
    // Gemini Pro variants first, then other Gemini, then Claude Opus, then other Claude, then rest
    if (lower.indexOf("gemini") !== -1 && lower.indexOf("pro") !== -1) return "0a_" + label
    if (lower.indexOf("gemini") !== -1) return "0b_" + label
    if (lower.indexOf("claude") !== -1 && lower.indexOf("opus") !== -1) return "1a_" + label
    if (lower.indexOf("claude") !== -1) return "1b_" + label
    return "2_" + label
  }

  var QUOTA_PERIOD_MS = 5 * 60 * 60 * 1000 // 5 hours

  function modelLine(ctx, label, remainingFraction, resetTime) {
    var clamped = Math.max(0, Math.min(1, remainingFraction))
    var used = Math.round((1 - clamped) * 100)
    return ctx.line.progress({
      label: label,
      used: used,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: resetTime || undefined,
      periodDurationMs: QUOTA_PERIOD_MS,
    })
  }

  // --- Probe ---

  function probe(ctx) {
    var discovery = discoverLs(ctx)
    if (!discovery) throw "Start Antigravity and try again."

    var port = findWorkingPort(ctx, discovery)
    if (!port) throw "Start Antigravity and try again."

    ctx.host.log.info("using LS at port " + port)

    var metadata = {
      ideName: "antigravity",
      extensionName: "antigravity",
      ideVersion: "unknown",
      locale: "en",
    }

    // Try GetUserStatus first, fall back to GetCommandModelConfigs
    var data = null
    try {
      data = callLs(ctx, port, discovery.csrf, "GetUserStatus", { metadata: metadata })
    } catch (e) {
      ctx.host.log.warn("GetUserStatus threw: " + String(e))
    }
    var hasUserStatus = data && data.userStatus

    if (!hasUserStatus) {
      ctx.host.log.warn("GetUserStatus failed, trying GetCommandModelConfigs")
      data = callLs(ctx, port, discovery.csrf, "GetCommandModelConfigs", { metadata: metadata })
    }

    // Parse model configs
    var configs
    if (hasUserStatus) {
      configs = (data.userStatus.cascadeModelConfigData || {}).clientModelConfigs || []
    } else if (data && data.clientModelConfigs) {
      configs = data.clientModelConfigs
    } else {
      throw "No data from language server."
    }

    var lines = []
    var plan = null

    // Plan name (only from GetUserStatus)
    if (hasUserStatus) {
      var ps = data.userStatus.planStatus || {}
      var pi = ps.planInfo || {}
      plan = pi.planName || null
    }

    // Model lines — deduplicate by normalized label (keep worst-case fraction)
    var deduped = {}
    for (var i = 0; i < configs.length; i++) {
      var c = configs[i]
      var qi = c.quotaInfo
      if (!qi || typeof qi.remainingFraction !== "number") continue
      var label = normalizeLabel(c.label)
      if (!deduped[label] || qi.remainingFraction < deduped[label].remainingFraction) {
        deduped[label] = {
          label: label,
          remainingFraction: qi.remainingFraction,
          resetTime: qi.resetTime,
        }
      }
    }

    var models = []
    var keys = Object.keys(deduped)
    for (var i = 0; i < keys.length; i++) {
      var m = deduped[keys[i]]
      m.sortKey = modelSortKey(m.label)
      models.push(m)
    }

    models.sort(function (a, b) {
      return a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0
    })

    for (var i = 0; i < models.length; i++) {
      lines.push(modelLine(ctx, models[i].label, models[i].remainingFraction, models[i].resetTime))
    }

    if (lines.length === 0) throw "No usage data available."

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "antigravity", probe: probe }
})()
