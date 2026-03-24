(function () {
  var CLOUD_SERVICE = "exa.seat_management_pb.SeatManagementService"
  var CLOUD_URL = "https://server.self-serve.windsurf.com"
  var CLOUD_COMPAT_VERSION = "1.108.2"
  var LOGIN_HINT = "Start Windsurf or sign in and try again."
  var QUOTA_HINT = "Windsurf quota data unavailable. Try again later."
  var DAY_MS = 24 * 60 * 60 * 1000
  var WEEK_MS = 7 * DAY_MS

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

  function readFiniteNumber(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value !== "string") return null
    var trimmed = value.trim()
    if (!trimmed) return null
    var parsed = Number(trimmed)
    return Number.isFinite(parsed) ? parsed : null
  }

  function clampPercent(value) {
    if (!Number.isFinite(value)) return 0
    if (value < 0) return 0
    if (value > 100) return 100
    return value
  }

  function loadApiKey(ctx, variant) {
    try {
      var rows = ctx.host.sqlite.query(
        variant.stateDb,
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

  function callCloud(ctx, apiKey, variant) {
    try {
      var resp = ctx.host.http.request({
        method: "POST",
        url: CLOUD_URL + "/" + CLOUD_SERVICE + "/GetUserStatus",
        headers: {
          "Content-Type": "application/json",
          "Connect-Protocol-Version": "1",
        },
        bodyText: JSON.stringify({
          metadata: {
            apiKey: apiKey,
            ideName: variant.ideName,
            ideVersion: CLOUD_COMPAT_VERSION,
            extensionName: variant.ideName,
            extensionVersion: CLOUD_COMPAT_VERSION,
            locale: "en",
          },
        }),
        timeoutMs: 15000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("cloud request returned status " + resp.status + " for " + variant.marker)
        if (ctx.util && typeof ctx.util.isAuthStatus === "function" && ctx.util.isAuthStatus(resp.status)) {
          return { __openusageAuthError: true }
        }
        return null
      }
      return ctx.util.tryParseJson(resp.bodyText)
    } catch (e) {
      ctx.host.log.warn("cloud request failed for " + variant.marker + ": " + String(e))
      return null
    }
  }

  function unixSecondsToIso(ctx, value) {
    var seconds = readFiniteNumber(value)
    if (seconds === null) return null
    return ctx.util.toIso(seconds * 1000)
  }

  function formatDollarsFromMicros(value) {
    var micros = readFiniteNumber(value)
    if (micros === null) return null
    if (micros < 0) micros = 0
    return "$" + (micros / 1000000).toFixed(2)
  }

  function buildQuotaLine(ctx, label, remainingPercent, resetsAt, periodDurationMs) {
    var remaining = readFiniteNumber(remainingPercent)
    if (remaining === null) return null
    var line = {
      label: label,
      used: clampPercent(100 - remaining),
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: periodDurationMs,
    }
    if (resetsAt) line.resetsAt = resetsAt
    return ctx.line.progress(line)
  }

  function hasQuotaContract(planStatus) {
    return (
      readFiniteNumber(planStatus && planStatus.dailyQuotaRemainingPercent) !== null &&
      readFiniteNumber(planStatus && planStatus.weeklyQuotaRemainingPercent) !== null &&
      readFiniteNumber(planStatus && planStatus.overageBalanceMicros) !== null &&
      readFiniteNumber(planStatus && planStatus.dailyQuotaResetAtUnix) !== null &&
      readFiniteNumber(planStatus && planStatus.weeklyQuotaResetAtUnix) !== null
    )
  }

  function buildOutput(ctx, userStatus) {
    var planStatus = (userStatus && userStatus.planStatus) || {}
    if (!hasQuotaContract(planStatus)) throw QUOTA_HINT

    var planInfo = planStatus.planInfo || {}
    var planName = typeof planInfo.planName === "string" && planInfo.planName.trim()
      ? planInfo.planName.trim()
      : "Unknown"

    var dailyReset = unixSecondsToIso(ctx, planStatus.dailyQuotaResetAtUnix)
    var weeklyReset = unixSecondsToIso(ctx, planStatus.weeklyQuotaResetAtUnix)
    var extraUsageBalance = formatDollarsFromMicros(planStatus.overageBalanceMicros)

    if (!dailyReset || !weeklyReset || !extraUsageBalance) throw QUOTA_HINT

    var dailyLine = buildQuotaLine(ctx, "Daily quota", planStatus.dailyQuotaRemainingPercent, dailyReset, DAY_MS)
    var weeklyLine = buildQuotaLine(ctx, "Weekly quota", planStatus.weeklyQuotaRemainingPercent, weeklyReset, WEEK_MS)

    if (!dailyLine || !weeklyLine) throw QUOTA_HINT

    return {
      plan: planName,
      lines: [
        dailyLine,
        weeklyLine,
        ctx.line.text({ label: "Extra usage balance", value: extraUsageBalance }),
      ],
    }
  }

  function probe(ctx) {
    var sawApiKey = false
    var sawAuthFailure = false

    for (var i = 0; i < VARIANTS.length; i++) {
      var variant = VARIANTS[i]
      var apiKey = loadApiKey(ctx, variant)
      if (!apiKey) continue
      sawApiKey = true

      var data = callCloud(ctx, apiKey, variant)
      if (data && data.__openusageAuthError) {
        sawAuthFailure = true
        continue
      }
      if (!data || !data.userStatus) continue

      try {
        return buildOutput(ctx, data.userStatus)
      } catch (e) {
        if (e === QUOTA_HINT) {
          ctx.host.log.warn("quota contract unavailable for " + variant.marker)
          continue
        }
        throw e
      }
    }

    if (sawAuthFailure) throw LOGIN_HINT
    if (sawApiKey) throw QUOTA_HINT
    throw LOGIN_HINT
  }

  globalThis.__openusage_plugin = { id: "windsurf", probe: probe }
})()
