(function () {
  // token_plan/remains is the officially documented Token Plan usage endpoint.
  // coding_plan/remains is retained as a legacy fallback for older accounts/regions.
  const GLOBAL_PRIMARY_USAGE_URL = "https://api.minimax.io/v1/token_plan/remains"
  const GLOBAL_FALLBACK_USAGE_URLS = [
    "https://www.minimax.io/v1/token_plan/remains",
    "https://api.minimax.io/v1/api/openplatform/coding_plan/remains",
  ]
  const CN_PRIMARY_USAGE_URL = "https://api.minimaxi.com/v1/token_plan/remains"
  const CN_FALLBACK_USAGE_URLS = [
    "https://www.minimaxi.com/v1/token_plan/remains",
    "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
  ]
  const GLOBAL_API_KEY_ENV_VARS = ["MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
  const CN_API_KEY_ENV_VARS = ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
  // Optional manual tier pin. The credit-based remains API exposes no plan/tier
  // field, so users can set this to surface their tier (e.g. "Plus"/"Max"/"Ultra").
  const PLAN_OVERRIDE_ENV_VARS = ["MINIMAX_PLAN", "MINIMAX_CODING_PLAN"]
  const DEFAULT_PLAN_NAME = "Token Plan"
  const INTERVAL_WINDOW_MS = 5 * 60 * 60 * 1000
  const WEEKLY_WINDOW_MS = 7 * 24 * 60 * 60 * 1000
  const WINDOW_TOLERANCE_MS = 10 * 60 * 1000

  // Token Plan tiers are credit/token based; the remains API no longer exposes
  // per-tier model-call counts (current_interval_total_count is 0). These tables
  // remain as a best-effort fallback for any account that still reports a tier
  // quota as a raw model-call total. They will not resolve for credit-based plans.
  const GLOBAL_MODEL_CALL_LIMIT_TO_PLAN = {
    1500: "Starter",
    4500: "Plus",
    15000: "Max",
    30000: "Ultra",
  }
  const CN_MODEL_CALL_LIMIT_TO_PLAN = {
    600: "Starter",
    1500: "Plus",
    4500: "Max",
    30000: "Ultra",
  }

  // model_name -> overview/detail line labels for the 5h interval and weekly windows.
  const KNOWN_MODEL_LABELS = {
    general: { interval: "Session", weekly: "Weekly" },
  }

  function readString(value) {
    if (typeof value !== "string") return null
    const trimmed = value.trim()
    return trimmed ? trimmed : null
  }

  function readNumber(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value !== "string") return null
    const trimmed = value.trim()
    if (!trimmed) return null
    const n = Number(trimmed)
    return Number.isFinite(n) ? n : null
  }

  function pickFirstString(values) {
    for (let i = 0; i < values.length; i += 1) {
      const value = readString(values[i])
      if (value) return value
    }
    return null
  }

  function clampPercent(value) {
    if (value < 0) return 0
    if (value > 100) return 100
    return value
  }

  function titleCaseModelName(value) {
    const raw = readString(value)
    if (!raw) return null
    return raw
      .replace(/[_]+/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/(^|[\s-])([a-z])/g, (_match, boundary, letter) => boundary + letter.toUpperCase())
  }

  function normalizePlanName(value) {
    const raw = readString(value)
    if (!raw) return null
    const compact = raw.replace(/\s+/g, " ").trim()
    const withoutPrefix = compact.replace(/^minimax\s+coding\s+plan\b[:\-]?\s*/i, "").trim()
    const base = withoutPrefix || compact
    if (!withoutPrefix && /(?:coding|token)\s+plan/i.test(compact)) return "Token Plan"

    const canonical = base
      .replace(/\s*-\s*/g, "-")
      .replace(/极速版/gi, "High-Speed")
      .replace(/highspeed/gi, "High-Speed")
      .replace(/high-speed/gi, "High-Speed")
      .replace(/\s+/g, " ")
      .trim()

    if (/^starter$/i.test(canonical)) return "Starter"
    if (/^plus$/i.test(canonical)) return "Plus"
    if (/^max$/i.test(canonical)) return "Max"
    if (/^ultra$/i.test(canonical)) return "Ultra"
    if (/^plus-?high-speed$/i.test(canonical)) return "Plus-High-Speed"
    if (/^max-?high-speed$/i.test(canonical)) return "Max-High-Speed"
    if (/^ultra-?high-speed$/i.test(canonical)) return "Ultra-High-Speed"
    return canonical
  }

  function inferPlanNameFromLimit(totalCount, endpointSelection) {
    const n = readNumber(totalCount)
    if (n === null || n <= 0) return null

    const normalized = Math.round(n)
    if (endpointSelection === "CN") {
      return CN_MODEL_CALL_LIMIT_TO_PLAN[normalized] || null
    }
    return GLOBAL_MODEL_CALL_LIMIT_TO_PLAN[normalized] || null
  }

  function epochToMs(epoch) {
    const n = readNumber(epoch)
    if (n === null) return null
    return Math.abs(n) < 1e10 ? n * 1000 : n
  }

  function inferRemainsMs(remainsRaw, endMs, nowMs, expectedWindowMs) {
    if (remainsRaw === null || remainsRaw <= 0) return null

    const asSecondsMs = remainsRaw * 1000
    const asMillisecondsMs = remainsRaw

    // If end_time exists, infer remains_time unit by whichever aligns best.
    if (endMs !== null) {
      const toEndMs = endMs - nowMs
      if (toEndMs > 0) {
        const secDelta = Math.abs(asSecondsMs - toEndMs)
        const msDelta = Math.abs(asMillisecondsMs - toEndMs)
        return secDelta <= msDelta ? asSecondsMs : asMillisecondsMs
      }
    }

    // Use expectedWindowMs constraint before defaulting.
    const maxExpectedMs = (expectedWindowMs || INTERVAL_WINDOW_MS) + WINDOW_TOLERANCE_MS
    const secondsLooksValid = asSecondsMs <= maxExpectedMs
    const millisecondsLooksValid = asMillisecondsMs <= maxExpectedMs

    if (secondsLooksValid && !millisecondsLooksValid) return asSecondsMs
    if (millisecondsLooksValid && !secondsLooksValid) return asMillisecondsMs
    if (secondsLooksValid && millisecondsLooksValid) return asSecondsMs

    const secOverflow = Math.abs(asSecondsMs - maxExpectedMs)
    const msOverflow = Math.abs(asMillisecondsMs - maxExpectedMs)
    return secOverflow <= msOverflow ? asSecondsMs : asMillisecondsMs
  }

  // Each model_remains entry now reports two enforced windows: a rolling 5-hour
  // interval and a weekly window. Both expose a remaining-percent field directly.
  const WINDOWS = [
    {
      key: "interval",
      percentField: "current_interval_remaining_percent",
      totalField: "current_interval_total_count",
      usageField: "current_interval_usage_count",
      startField: "start_time",
      endField: "end_time",
      remainsField: "remains_time",
      expectedWindowMs: INTERVAL_WINDOW_MS,
    },
    {
      key: "weekly",
      percentField: "current_weekly_remaining_percent",
      totalField: "current_weekly_total_count",
      usageField: "current_weekly_usage_count",
      startField: "weekly_start_time",
      endField: "weekly_end_time",
      remainsField: "weekly_remains_time",
      expectedWindowMs: WEEKLY_WINDOW_MS,
    },
  ]

  function readModelName(item) {
    return readString(item.model_name) || readString(item.modelName)
  }

  function windowLabel(item, windowKey) {
    const modelName = (readModelName(item) || "").toLowerCase()
    const known = KNOWN_MODEL_LABELS[modelName]
    if (known) return known[windowKey]

    const display = titleCaseModelName(readModelName(item)) || "Usage"
    return windowKey === "weekly" ? display + " (Weekly)" : display
  }

  // Returns a 0-100 used percentage for the window, or null when the window
  // carries no usable data. Prefers the API-provided remaining-percent field;
  // falls back to count math (usage_count is the remaining count) when absent.
  function computeWindowUsedPercent(item, win) {
    const remainingPercent = readNumber(item[win.percentField])
    if (remainingPercent !== null) {
      return clampPercent(Math.round(100 - remainingPercent))
    }

    const total = readNumber(item[win.totalField])
    if (total === null || total <= 0) return null
    const remaining = readNumber(item[win.usageField])
    if (remaining === null) return null
    return clampPercent(Math.round(((total - remaining) / total) * 100))
  }

  function computeWindowTiming(ctx, item, win, nowMs) {
    const startMs = epochToMs(item[win.startField])
    const endMs = epochToMs(item[win.endField])
    const remainsRaw = readNumber(item[win.remainsField])
    const remainsMs = inferRemainsMs(remainsRaw, endMs, nowMs, win.expectedWindowMs)

    let resetsAt = endMs !== null ? ctx.util.toIso(endMs) : null
    if (!resetsAt && remainsMs !== null) resetsAt = ctx.util.toIso(nowMs + remainsMs)

    let periodDurationMs = null
    if (startMs !== null && endMs !== null && endMs > startMs) periodDurationMs = endMs - startMs

    return { resetsAt, periodDurationMs }
  }

  function parseModelRemainEntries(ctx, item, nowMs) {
    if (!item || typeof item !== "object") return []

    const entries = []
    for (let i = 0; i < WINDOWS.length; i += 1) {
      const win = WINDOWS[i]
      const usedPercent = computeWindowUsedPercent(item, win)
      if (usedPercent === null) continue

      const timing = computeWindowTiming(ctx, item, win, nowMs)
      entries.push({
        label: windowLabel(item, win.key),
        used: usedPercent,
        resetsAt: timing.resetsAt,
        periodDurationMs: timing.periodDurationMs,
      })
    }
    return entries
  }

  function loadApiKey(ctx, endpointSelection) {
    const envVars = endpointSelection === "CN" ? CN_API_KEY_ENV_VARS : GLOBAL_API_KEY_ENV_VARS
    for (let i = 0; i < envVars.length; i += 1) {
      const name = envVars[i]
      let value = null
      try {
        value = ctx.host.env.get(name)
      } catch (e) {
        ctx.host.log.warn("env read failed for " + name + ": " + String(e))
      }
      const key = readString(value)
      if (key) {
        ctx.host.log.info("api key loaded from " + name)
        return { value: key, source: name }
      }
    }
    return null
  }

  function readPlanOverride(ctx) {
    for (let i = 0; i < PLAN_OVERRIDE_ENV_VARS.length; i += 1) {
      const name = PLAN_OVERRIDE_ENV_VARS[i]
      let value = null
      try {
        value = ctx.host.env.get(name)
      } catch (e) {
        ctx.host.log.warn("env read failed for " + name + ": " + String(e))
      }
      const plan = readString(value)
      if (plan) return plan
    }
    return null
  }

  function getUsageUrls(endpointSelection) {
    if (endpointSelection === "CN") {
      return [CN_PRIMARY_USAGE_URL].concat(CN_FALLBACK_USAGE_URLS)
    }
    return [GLOBAL_PRIMARY_USAGE_URL].concat(GLOBAL_FALLBACK_USAGE_URLS)
  }

  function endpointAttempts(ctx) {
    // AUTO: if CN key exists, try CN first; otherwise try GLOBAL first.
    let cnApiKeyValue = null
    try {
      cnApiKeyValue = ctx.host.env.get("MINIMAX_CN_API_KEY")
    } catch (e) {
      ctx.host.log.warn("env read failed for MINIMAX_CN_API_KEY: " + String(e))
    }
    if (readString(cnApiKeyValue)) return ["CN", "GLOBAL"]
    return ["GLOBAL", "CN"]
  }

  function formatAuthError() {
    return "Session expired. Check your MiniMax API key."
  }

  /**
   * Tries multiple URL candidates and returns the first successful response.
   * @returns {object} parsed JSON response
   * @throws {string} error message
   */
  function tryUrls(ctx, urls, apiKey) {
    let lastStatus = null
    let hadNetworkError = false
    let authStatusCount = 0

    for (let i = 0; i < urls.length; i += 1) {
      const url = urls[i]
      let resp
      try {
        resp = ctx.util.request({
          method: "GET",
          url: url,
          headers: {
            Authorization: "Bearer " + apiKey,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          timeoutMs: 15000,
        })
      } catch (e) {
        hadNetworkError = true
        ctx.host.log.warn("request failed (" + url + "): " + String(e))
        continue
      }

      if (ctx.util.isAuthStatus(resp.status)) {
        authStatusCount += 1
        ctx.host.log.warn("request returned auth status " + resp.status + " (" + url + ")")
        continue
      }
      if (resp.status < 200 || resp.status >= 300) {
        lastStatus = resp.status
        ctx.host.log.warn("request returned status " + resp.status + " (" + url + ")")
        continue
      }

      const parsed = ctx.util.tryParseJson(resp.bodyText)
      if (!parsed || typeof parsed !== "object") {
        ctx.host.log.warn("request returned invalid JSON (" + url + ")")
        continue
      }

      return parsed
    }

    if (authStatusCount > 0 && lastStatus === null && !hadNetworkError) {
      throw formatAuthError()
    }
    if (lastStatus !== null) throw "Request failed (HTTP " + lastStatus + "). Try again later."
    if (hadNetworkError) throw "Request failed. Check your connection."
    throw "Could not parse usage data."
  }

  function readGeneralIntervalTotal(modelRemains) {
    for (let i = 0; i < modelRemains.length; i += 1) {
      const item = modelRemains[i]
      if (!item || typeof item !== "object") continue
      if ((readModelName(item) || "").toLowerCase() !== "general") continue
      return readNumber(item.current_interval_total_count ?? item.currentIntervalTotalCount)
    }
    return null
  }

  function parsePayloadShape(ctx, payload, endpointSelection) {
    if (!payload || typeof payload !== "object") return null

    const data = payload.data && typeof payload.data === "object" ? payload.data : payload
    const baseResp = (data && data.base_resp) || payload.base_resp || null
    const statusCode = readNumber(baseResp && baseResp.status_code)
    const statusMessage = readString(baseResp && baseResp.status_msg)

    if (statusCode !== null && statusCode !== 0) {
      const normalized = (statusMessage || "").toLowerCase()
      if (
        statusCode === 1004 ||
        normalized.includes("cookie") ||
        normalized.includes("log in") ||
        normalized.includes("login")
      ) {
        throw formatAuthError()
      }
      throw statusMessage
        ? "MiniMax API error: " + statusMessage
        : "MiniMax API error (status " + statusCode + ")."
    }

    const modelRemains =
      (Array.isArray(data.model_remains) && data.model_remains) ||
      (Array.isArray(payload.model_remains) && payload.model_remains) ||
      (Array.isArray(data.modelRemains) && data.modelRemains) ||
      (Array.isArray(payload.modelRemains) && payload.modelRemains) ||
      null

    if (!modelRemains || modelRemains.length === 0) return null

    const nowMs = Date.now()
    const entries = []
    const seenLabels = Object.create(null)

    for (let i = 0; i < modelRemains.length; i += 1) {
      const itemEntries = parseModelRemainEntries(ctx, modelRemains[i], nowMs)
      for (let j = 0; j < itemEntries.length; j += 1) {
        const entry = itemEntries[j]
        if (seenLabels[entry.label]) continue
        seenLabels[entry.label] = true
        entries.push(entry)
      }
    }

    if (entries.length === 0) return null

    const explicitPlanName = normalizePlanName(pickFirstString([
      data.current_subscribe_title,
      data.plan_name,
      data.plan,
      data.current_plan_title,
      data.combo_title,
      payload.current_subscribe_title,
      payload.plan_name,
      payload.plan,
    ]))
    const inferredPlanName = inferPlanNameFromLimit(
      readGeneralIntervalTotal(modelRemains),
      endpointSelection
    )
    const planName = explicitPlanName || inferredPlanName

    return {
      planName,
      entries,
    }
  }

  function fetchUsagePayload(ctx, apiKey, endpointSelection) {
    return tryUrls(ctx, getUsageUrls(endpointSelection), apiKey)
  }

  function probe(ctx) {
    const attempts = endpointAttempts(ctx)
    let lastError = null
    let parsed = null
    let successfulEndpoint = null

    for (let i = 0; i < attempts.length; i += 1) {
      const endpoint = attempts[i]
      const apiKeyInfo = loadApiKey(ctx, endpoint)
      if (!apiKeyInfo) continue
      try {
        const payload = fetchUsagePayload(ctx, apiKeyInfo.value, endpoint)
        parsed = parsePayloadShape(ctx, payload, endpoint)
        if (parsed) {
          successfulEndpoint = endpoint
          break
        }
        if (!lastError) lastError = "Could not parse usage data."
      } catch (e) {
        if (!lastError) lastError = String(e)
      }
    }

    if (!parsed) {
      if (lastError) throw lastError
      throw "MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY."
    }

    const lines = parsed.entries.map((entry) => {
      const line = {
        label: entry.label,
        used: entry.used,
        limit: 100,
        format: { kind: "percent" },
      }
      if (entry.resetsAt) line.resetsAt = entry.resetsAt
      if (entry.periodDurationMs !== null) line.periodDurationMs = entry.periodDurationMs
      return ctx.line.progress(line)
    })

    // Plan-name priority: explicit API field / count-inference (parsed.planName)
    // -> manual MINIMAX_PLAN override -> generic baseline so the line is never blank.
    const planName =
      parsed.planName || normalizePlanName(readPlanOverride(ctx)) || DEFAULT_PLAN_NAME
    const regionLabel = successfulEndpoint === "CN" ? " (CN)" : " (GLOBAL)"

    const result = { lines, plan: planName + regionLabel }
    return result
  }

  globalThis.__openusage_plugin = { id: "minimax", probe }
})()
