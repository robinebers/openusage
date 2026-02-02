(function () {
  const DEFAULT_CONFIG = {
    // By default this plugin is intentionally non-deterministic / failure-prone.
    // If you want to pin a specific mode, set { pinned: true, mode: "..." }.
    mode: "chaos",
    pinned: false,
  }

  function lineText(label, value, color) {
    const line = { type: "text", label, value }
    if (color) line.color = color
    return line
  }

  function lineProgress(label, value, max, unit, color) {
    return { type: "progress", label, value, max, unit, color }
  }

  function lineBadge(label, text, color) {
    const line = { type: "badge", label, text }
    if (color) line.color = color
    return line
  }

  function safeString(value) {
    try {
      if (value === null) return "null"
      if (value === undefined) return "undefined"
      if (typeof value === "string") return value
      return JSON.stringify(value)
    } catch {
      return String(value)
    }
  }

  function readJson(ctx, path) {
    try {
      if (!ctx.host.fs.exists(path)) return null
      const text = ctx.host.fs.readText(path)
      return JSON.parse(text)
    } catch {
      return null
    }
  }

  function writeJson(ctx, path, value) {
    try {
      ctx.host.fs.writeText(path, JSON.stringify(value, null, 2))
    } catch {}
  }

  function readConfig(ctx, configPath) {
    const parsed = readJson(ctx, configPath)

    // Initialize config on first run.
    if (!parsed || typeof parsed !== "object") {
      writeJson(ctx, configPath, DEFAULT_CONFIG)
      return DEFAULT_CONFIG
    }

    const pinned = typeof parsed.pinned === "boolean" ? parsed.pinned : false
    const mode = parsed.mode ?? DEFAULT_CONFIG.mode

    // Auto-migrate legacy configs that were auto-created as { mode: "ok" }.
    if (!pinned && mode === "ok") {
      writeJson(ctx, configPath, DEFAULT_CONFIG)
      return DEFAULT_CONFIG
    }

    return { mode, pinned }
  }

  function chooseChaosCase(ctx, pluginDataDir) {
    const statePath = pluginDataDir + "/state.json"
    const state = readJson(ctx, statePath)
    const prevCounter = Number(state && state.counter)
    const counter = Number.isFinite(prevCounter) && prevCounter >= 0 ? prevCounter + 1 : 0

    const cases = [
      // "Looks fine" baseline
      "ok",

      // Subtle API misuse that doesn't crash but yields wrong UI
      "progress_max_na",
      "progress_value_string",
      "progress_value_nan",
      "badge_text_number",

      // Hard schema issues (host returns a single Error badge)
      "lines_not_array",
      "line_not_object",

      // Explicit runtime failures
      "throw",
      "reject",
      "unresolved_promise",
      "http_throw",
      "sqlite_throw",
    ]

    const idx = counter % cases.length
    const picked = cases[idx]

    writeJson(ctx, statePath, { counter, picked, nowIso: ctx.nowIso })
    return { counter, picked }
  }

  function writeLastCase(ctx, pluginDataDir, picked) {
    writeJson(ctx, pluginDataDir + "/last_case.json", { picked, nowIso: ctx.nowIso })
  }

  function probe(ctx) {
    const configPath = ctx.app.pluginDataDir + "/config.json"
    const config = readConfig(ctx, configPath)
    const pinned = !!config.pinned
    const requestedMode = config.mode ?? DEFAULT_CONFIG.mode
    const effectiveMode = pinned ? requestedMode : "chaos"

    let mode = effectiveMode
    if (effectiveMode === "chaos") {
      const picked = chooseChaosCase(ctx, ctx.app.pluginDataDir).picked
      writeLastCase(ctx, ctx.app.pluginDataDir, picked)
      mode = picked
    }

    // Non-throwing modes should always include a “where to change this” hint.
    const hintLines = [
      lineBadge("Mode", safeString(effectiveMode), "#000000"),
      lineText("Config", configPath),
    ]

    if (mode === "ok") {
      return {
        lines: [
          ...hintLines,
          effectiveMode === "chaos" ? lineBadge("Case", "ok", "#000000") : null,
          lineProgress("Percent", 42, 100, "percent", "#22c55e"),
          lineProgress("Dollars", 12.34, 100, "dollars", "#3b82f6"),
          lineText("Now", ctx.nowIso),
        ].filter(Boolean),
      }
    }

    if (mode === "throw") {
      throw new Error("mock plugin: thrown error")
    }

    if (mode === "reject") {
      return Promise.reject(new Error("mock plugin: rejected promise"))
    }

    if (mode === "unresolved_promise") {
      return new Promise(function () {
        // Intentionally never resolves/rejects.
      })
    }

    if (mode === "non_object") {
      return "not an object"
    }

    if (mode === "missing_lines") {
      return {}
    }

    if (mode === "unknown_line_type") {
      return {
        lines: [
          ...hintLines,
          { type: "nope", label: "Bad", value: "data" },
        ],
      }
    }

    if (mode === "lines_not_array") {
      // Host expects `lines` to be an Array. This becomes "missing lines".
      return {
        lines: "nope",
      }
    }

    if (mode === "line_not_object") {
      // Host expects each line to be an object. This becomes "invalid line at index N".
      return {
        lines: [
          ...hintLines,
          "definitely not an object",
        ],
      }
    }

    if (mode === "progress_max_na") {
      // Common plugin bug: max is not a number (e.g. "N/A"). Host coerces to 0.0.
      // UI will show "42%" but bar stays empty because max <= 0.
      return {
        lines: [
          ...hintLines,
          lineBadge("Case", "progress.max = \"N/A\" (string)", "#000000"),
          { type: "progress", label: "Percent", value: 42, max: "N/A", unit: "percent", color: "#ef4444" },
        ],
      }
    }

    if (mode === "progress_value_string") {
      // Common plugin bug: value is a string. Host coerces to 0.0.
      // UI will show 0% even though the plugin tried to say "42".
      return {
        lines: [
          ...hintLines,
          lineBadge("Case", "progress.value = \"42\" (string)", "#000000"),
          { type: "progress", label: "Percent", value: "42", max: 100, unit: "percent", color: "#ef4444" },
        ],
      }
    }

    if (mode === "progress_value_nan") {
      // Common plugin bug: value is NaN. Host detects non-finite -> value=-1, max=0.
      // UI shows N/A.
      return {
        lines: [
          ...hintLines,
          lineBadge("Case", "progress.value = NaN", "#000000"),
          { type: "progress", label: "Percent", value: 0 / 0, max: 100, unit: "percent", color: "#ef4444" },
        ],
      }
    }

    if (mode === "badge_text_number") {
      // Common plugin bug: badge.text isn't a string. Host reads empty string.
      return {
        lines: [
          ...hintLines,
          lineBadge("Case", "badge.text = 123 (number)", "#000000"),
          { type: "badge", label: "Status", text: 123, color: "#ef4444" },
        ],
      }
    }

    if (mode === "fs_throw") {
      // Uncaught host FS exception -> host should report "probe() failed".
      ctx.host.fs.readText("/definitely/not/a/real/path-" + String(Date.now()))
      return { lines: hintLines }
    }

    if (mode === "http_throw") {
      // Invalid HTTP method -> host throws -> host should report "probe() failed".
      ctx.host.http.request({
        method: "NOPE_METHOD",
        url: "https://example.com/",
        timeoutMs: 1000,
      })
      return { lines: hintLines }
    }

    if (mode === "sqlite_throw") {
      // Dot-commands are blocked by host -> uncaught -> host should report "probe() failed".
      ctx.host.sqlite.query(ctx.app.appDataDir + "/does-not-matter.db", ".schema")
      return { lines: hintLines }
    }

    // Unknown mode: don’t throw; make it obvious.
    return {
      lines: [
        ...hintLines,
        lineBadge("Warning", "unknown mode: " + safeString(mode), "#f59e0b"),
      ],
    }
  }

  globalThis.__openusage_plugin = { id: "mock", probe }
})()
