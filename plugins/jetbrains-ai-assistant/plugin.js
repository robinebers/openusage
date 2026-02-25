(function () {
  var QUOTA_FILENAME = "AIAssistantQuotaManager2.xml"

  // JetBrains stores AI quota in 1e-5 credit units; divide by this to get credits.
  var CREDIT_UNIT_SCALE = 100000

  var PRODUCT_PREFIXES = [
    "Aqua",
    "AndroidStudio",
    "CLion",
    "DataGrip",
    "DataSpell",
    "GoLand",
    "IdeaIC",
    "IntelliJIdea",
    "IntelliJIdeaCE",
    "PhpStorm",
    "PyCharm",
    "PyCharmCE",
    "Rider",
    "RubyMine",
    "RustRover",
    "WebStorm",
    "Writerside",
  ]

  function platformBaseDirs(platform) {
    if (platform === "macos") {
      return ["~/Library/Application Support/JetBrains"]
    }
    if (platform === "linux") {
      return ["~/.config/JetBrains"]
    }
    if (platform === "windows") {
      return ["~/AppData/Roaming/JetBrains"]
    }
    return [
      "~/Library/Application Support/JetBrains",
      "~/.config/JetBrains",
      "~/AppData/Roaming/JetBrains",
    ]
  }

  function isLikelyIdeDirName(name) {
    if (typeof name !== "string") return false
    var trimmed = name.trim()
    if (!trimmed) return false
    var hasPrefix = false
    for (var i = 0; i < PRODUCT_PREFIXES.length; i += 1) {
      if (trimmed.indexOf(PRODUCT_PREFIXES[i]) === 0) {
        hasPrefix = true
        break
      }
    }
    if (!hasPrefix) return false
    return /\d{4}\.\d/.test(trimmed)
  }

  function safeListDir(ctx, path) {
    if (
      !ctx.host.fs ||
      typeof ctx.host.fs.listDir !== "function" ||
      !ctx.host.fs.exists(path)
    ) {
      return []
    }

    try {
      var entries = ctx.host.fs.listDir(path)
      return Array.isArray(entries) ? entries : []
    } catch (e) {
      ctx.host.log.warn("listDir failed for " + path + ": " + String(e))
      return []
    }
  }

  function buildQuotaPaths(ctx) {
    var bases = platformBaseDirs(ctx.app.platform)
    var paths = []
    var seen = Object.create(null)
    for (var b = 0; b < bases.length; b += 1) {
      var base = bases[b]
      var entries = safeListDir(ctx, base)
      for (var i = 0; i < entries.length; i += 1) {
        var dirName = entries[i]
        if (!isLikelyIdeDirName(dirName)) continue
        var quotaPath = base + "/" + dirName + "/options/" + QUOTA_FILENAME
        if (!ctx.host.fs.exists(quotaPath)) continue
        if (!seen[quotaPath]) {
          seen[quotaPath] = true
          paths.push(quotaPath)
        }
      }
    }
    return paths
  }

  function decodeXmlEntities(text) {
    if (!text) return ""
    return String(text)
      .replace(/&#10;/g, "\n")
      .replace(/&#13;/g, "\r")
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&")
  }

  function parseOptionJson(ctx, xml, optionName) {
    var elemMatch = xml.match(new RegExp('<option\\b[^>]*\\bname="' + optionName + '"[^>]*/>'))
    if (!elemMatch) return null
    var valueMatch = elemMatch[0].match(/\bvalue="([^"]*)"/)
    if (!valueMatch) return null
    return ctx.util.tryParseJson(decodeXmlEntities(valueMatch[1]))
  }

  function toNumber(value) {
    var n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function clamp(value, min, max) {
    if (value < min) return min
    if (value > max) return max
    return value
  }

  function normalizeQuota(quotaInfo) {
    if (!quotaInfo || typeof quotaInfo !== "object") return null

    var maximum = toNumber(quotaInfo.maximum)
    var used = toNumber(quotaInfo.current)
    var remaining = toNumber(quotaInfo.available)

    var tariff = quotaInfo.tariffQuota && typeof quotaInfo.tariffQuota === "object"
      ? quotaInfo.tariffQuota
      : null
    var topUp = quotaInfo.topUpQuota && typeof quotaInfo.topUpQuota === "object"
      ? quotaInfo.topUpQuota
      : null

    if (maximum === null) {
      var tariffMaximum = tariff ? toNumber(tariff.maximum) : null
      var topUpMaximum = topUp ? toNumber(topUp.maximum) : null
      if (tariffMaximum !== null || topUpMaximum !== null) {
        maximum = (tariffMaximum !== null ? tariffMaximum : 0) + (topUpMaximum !== null ? topUpMaximum : 0)
      }
    }

    if (used === null) {
      var tariffUsed = tariff ? toNumber(tariff.current) : null
      var topUpUsed = topUp ? toNumber(topUp.current) : null
      if (tariffUsed !== null || topUpUsed !== null) {
        used = (tariffUsed !== null ? tariffUsed : 0) + (topUpUsed !== null ? topUpUsed : 0)
      }
    }

    if (remaining === null) {
      var tariffRemaining = tariff ? toNumber(tariff.available) : null
      var topUpRemaining = topUp ? toNumber(topUp.available) : null
      if (tariffRemaining !== null || topUpRemaining !== null) {
        remaining = (tariffRemaining !== null ? tariffRemaining : 0) + (topUpRemaining !== null ? topUpRemaining : 0)
      }
    }

    if (remaining === null && maximum !== null && used !== null) {
      remaining = maximum - used
    }

    if (maximum === null || maximum <= 0 || used === null) return null

    used = clamp(used, 0, maximum)
    if (remaining !== null) remaining = clamp(remaining, 0, maximum)

    return {
      used: used,
      maximum: maximum,
      remaining: remaining,
      until: quotaInfo.until || null,
    }
  }

  function readQuotaState(ctx, path) {
    if (!ctx.host.fs.exists(path)) return null
    try {
      var xml = ctx.host.fs.readText(path)
      var quotaInfo = parseOptionJson(ctx, xml, "quotaInfo")
      var nextRefill = parseOptionJson(ctx, xml, "nextRefill")
      var quota = normalizeQuota(quotaInfo)
      if (!quota) return null
      return { path: path, quota: quota, nextRefill: nextRefill }
    } catch (e) {
      ctx.host.log.warn("failed reading quota state " + path + ": " + String(e))
      return null
    }
  }

  // Handles only simple single-component durations (PTnH, PnD, PnW).
  // JetBrains currently uses values like PT720H or P30D.
  function parseIsoDurationMs(value) {
    if (typeof value !== "string" || !value) return null

    var h = value.match(/^PT(\d+)H$/)
    if (h) return Number(h[1]) * 60 * 60 * 1000

    var d = value.match(/^P(\d+)D$/)
    if (d) return Number(d[1]) * 24 * 60 * 60 * 1000

    var w = value.match(/^P(\d+)W$/)
    if (w) return Number(w[1]) * 7 * 24 * 60 * 60 * 1000

    return null
  }

  function pickBestState(ctx, states) {
    var best = null
    var bestMs = -Infinity

    for (var i = 0; i < states.length; i += 1) {
      var state = states[i]
      var untilMs = null

      if (state.quota.until) {
        untilMs = ctx.util.parseDateMs(state.quota.until)
      }
      if (untilMs === null && state.nextRefill && state.nextRefill.next) {
        untilMs = ctx.util.parseDateMs(state.nextRefill.next)
      }
      if (untilMs === null) untilMs = -Infinity

      if (!best || untilMs > bestMs) {
        best = state
        bestMs = untilMs
        continue
      }

      if (untilMs === bestMs) {
        var currentRatio =
          state.quota.maximum > 0 ? state.quota.used / state.quota.maximum : 0
        var bestRatio =
          best.quota.maximum > 0 ? best.quota.used / best.quota.maximum : 0
        if (currentRatio > bestRatio) {
          best = state
          continue
        }
        if (currentRatio === bestRatio && state.quota.used > best.quota.used) {
          best = state
          continue
        }
      }
    }

    return best
  }

  function formatDecimal(value, places) {
    if (!Number.isFinite(value)) return null
    var factor = Math.pow(10, places)
    var rounded = Math.round(value * factor) / factor
    return rounded.toFixed(places).replace(/\.?0+$/, "")
  }

  function detectDisplayScale(quota, nextRefill) {
    var maxAbs = Math.max(
      Math.abs(quota.maximum || 0),
      Math.abs(quota.used || 0),
      Math.abs(quota.remaining || 0)
    )

    if (nextRefill && nextRefill.tariff && typeof nextRefill.tariff === "object") {
      var tariffAmount = toNumber(nextRefill.tariff.amount)
      if (tariffAmount !== null) {
        maxAbs = Math.max(maxAbs, Math.abs(tariffAmount))
      }
    }

    if (maxAbs >= CREDIT_UNIT_SCALE) return CREDIT_UNIT_SCALE
    return 1
  }

  function probe(ctx) {
    var paths = buildQuotaPaths(ctx)
    var states = []

    for (var i = 0; i < paths.length; i += 1) {
      var state = readQuotaState(ctx, paths[i])
      if (state) states.push(state)
    }

    if (states.length === 0) {
      throw paths.length > 0
        ? "JetBrains AI Assistant quota data unavailable. Open AI Assistant once and try again."
        : "JetBrains AI Assistant not detected. Open a JetBrains IDE with AI Assistant enabled."
    }

    var chosen = pickBestState(ctx, states)
    var quota = chosen.quota
    var scale = detectDisplayScale(quota, chosen.nextRefill)
    var usedPercent = (quota.used / quota.maximum) * 100
    if (!Number.isFinite(usedPercent)) usedPercent = 0
    usedPercent = clamp(usedPercent, 0, 100)
    var line = {
      label: "Quota",
      used: usedPercent,
      limit: 100,
      format: { kind: "percent" },
    }

    var resetSource = null
    if (chosen.nextRefill && chosen.nextRefill.next) {
      resetSource = chosen.nextRefill.next
    } else if (quota.until) {
      resetSource = quota.until
    }

    var resetsAt = ctx.util.toIso(resetSource)
    if (resetsAt) line.resetsAt = resetsAt

    var duration = null
    if (
      chosen.nextRefill &&
      chosen.nextRefill.tariff &&
      typeof chosen.nextRefill.tariff === "object"
    ) {
      duration = parseIsoDurationMs(chosen.nextRefill.tariff.duration)
    }
    if (duration) line.periodDurationMs = duration

    var lines = [ctx.line.progress(line)]

    lines.push(
      ctx.line.text({
        label: "Used",
        value:
          scale > 1
            ? formatDecimal(quota.used / scale, 2) + " / " + formatDecimal(quota.maximum / scale, 2) + " credits"
            : String(quota.used),
      })
    )

    if (quota.remaining !== null) {
      lines.push(
        ctx.line.text({
          label: "Remaining",
          value: scale > 1 ? formatDecimal(quota.remaining / scale, 2) + " credits" : String(quota.remaining),
        })
      )
    }

    ctx.host.log.info("quota loaded from " + chosen.path)

    return { lines: lines }
  }

  globalThis.__openusage_plugin = { id: "jetbrains-ai-assistant", probe: probe }
})()
