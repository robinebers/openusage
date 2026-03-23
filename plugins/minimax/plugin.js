(function () {
  const GLOBAL_PRIMARY_USAGE_URL = "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
  const GLOBAL_FALLBACK_USAGE_URLS = [
    "https://api.minimax.io/v1/coding_plan/remains",
    "https://www.minimax.io/v1/api/openplatform/coding_plan/remains",
  ]
  const CN_PRIMARY_USAGE_URL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"
  const CN_FALLBACK_USAGE_URLS = [
    "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains",
    "https://api.minimaxi.com/v1/coding_plan/remains",
  ]
  const GLOBAL_API_KEY_ENV_VARS = ["MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
  const CN_API_KEY_ENV_VARS = ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
  const CODING_PLAN_WINDOW_MS = 5 * 60 * 60 * 1000
  const CODING_PLAN_WINDOW_TOLERANCE_MS = 10 * 60 * 1000
  const DAILY_WINDOW_MS = 24 * 60 * 60 * 1000
  const GLOBAL_PROMPT_LIMIT_TO_PLAN = {
    100: "Starter",
    300: "Plus",
    1000: "Max",
    2000: "Ultra-High-Speed",
  }
  const GLOBAL_MODEL_CALL_LIMIT_TO_PLAN = {
    1500: "Starter",
    4500: "Plus",
    15000: "Max",
    30000: "Ultra-High-Speed",
  }
  const CN_PROMPT_LIMIT_TO_PLAN = {
    40: "Starter",
    100: "Plus",
    300: "Max",
    2000: "Ultra-High-Speed",
  }
  const CN_MODEL_CALL_LIMIT_TO_PLAN = {
    600: "Starter",
    1500: "Plus",
    4500: "Max",
    30000: "Ultra-High-Speed",
  }
  const GLOBAL_COMPANION_QUOTA_HINTS = {
    4500: {
      image01: { 50: "Plus", 100: "Plus-High-Speed" },
      speechHd: { 4000: "Plus", 9000: "Plus-High-Speed" },
    },
    15000: {
      image01: { 120: "Max", 200: "Max-High-Speed" },
      speechHd: { 11000: "Max", 19000: "Max-High-Speed" },
    },
  }
  const CN_COMPANION_QUOTA_HINTS = {
    1500: {
      image01: { 50: "Plus", 100: "Plus-High-Speed" },
      speechHd: { 4000: "Plus", 9000: "Plus-High-Speed" },
    },
    4500: {
      image01: { 120: "Max", 200: "Max-High-Speed" },
      speechHd: { 11000: "Max", 19000: "Max-High-Speed" },
    },
  }
  const MODEL_CALLS_SUFFIX = "model-calls"

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

  function normalizePlanName(value) {
    const raw = readString(value)
    if (!raw) return null
    const compact = raw.replace(/\s+/g, " ").trim()
    const withoutPrefix = compact.replace(/^minimax\s+coding\s+plan\b[:\-]?\s*/i, "").trim()
    const base = withoutPrefix || compact
    if (/coding\s+plan/i.test(compact) && !withoutPrefix) return "Coding Plan"

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
      return CN_MODEL_CALL_LIMIT_TO_PLAN[normalized] || CN_PROMPT_LIMIT_TO_PLAN[normalized] || null
    }
    return GLOBAL_MODEL_CALL_LIMIT_TO_PLAN[normalized] || GLOBAL_PROMPT_LIMIT_TO_PLAN[normalized] || null
  }

  function readUsageRawName(item) {
    return normalizeUsageName(
      pickFirstString([
        item.model_name,
        item.modelName,
        item.resource_name,
        item.resourceName,
        item.name,
      ])
    )
  }

  function normalizeUsageNameKey(value) {
    return value ? value.toLowerCase() : ""
  }

  function isSpeechHdUsageName(name) {
    return (
      name.includes("text to speech hd") ||
      name.includes("speech 2.8") ||
      /^speech(?:-[\d.]+)?-hd$/.test(name)
    )
  }

  function isSpeechTurboUsageName(name) {
    return (
      name.includes("text to speech turbo") ||
      /^speech(?:-[\d.]+)?-turbo$/.test(name)
    )
  }

  function isImage01UsageName(name) {
    return name.includes("image-01")
  }

  function isSessionUsageName(name) {
    return (
      name.includes("minimax-m") ||
      name.includes("text model") ||
      name.includes("coding")
    )
  }

  function inferPlanNameFromSignals(signals, endpointSelection) {
    const sessionTotal = readNumber(signals && signals.sessionTotal)
    if (sessionTotal === null || sessionTotal <= 0) return null

    const basePlanName = inferPlanNameFromLimit(sessionTotal, endpointSelection)
    if (!basePlanName) return null

    const hintTable =
      endpointSelection === "CN" ? CN_COMPANION_QUOTA_HINTS : GLOBAL_COMPANION_QUOTA_HINTS
    const hintSpec = hintTable[Math.round(sessionTotal)]
    if (!hintSpec) return basePlanName

    const image01Total = readNumber(signals.image01Total)
    const speechHdTotal = readNumber(signals.speechHdTotal)
    const candidates = []

    if (image01Total !== null) {
      const planFromImage = hintSpec.image01[Math.round(image01Total)]
      if (planFromImage) candidates.push(planFromImage)
    }
    if (speechHdTotal !== null) {
      const planFromSpeech = hintSpec.speechHd[Math.round(speechHdTotal)]
      if (planFromSpeech) candidates.push(planFromSpeech)
    }

    if (candidates.length === 0) return basePlanName
    if (candidates.every((candidate) => candidate === candidates[0])) return candidates[0]
    return basePlanName
  }

  function collectPlanInferenceSignals(modelRemains) {
    const signals = {
      sessionTotal: null,
      speechHdTotal: null,
      image01Total: null,
    }
    let fallbackSessionTotal = null

    for (let i = 0; i < modelRemains.length; i += 1) {
      const item = modelRemains[i]
      if (!item || typeof item !== "object") continue

      const total = readNumber(item.current_interval_total_count ?? item.currentIntervalTotalCount)
      if (total === null || total <= 0) continue

      const normalizedTotal = Math.round(total)
      if (fallbackSessionTotal === null) fallbackSessionTotal = normalizedTotal

      const name = normalizeUsageNameKey(readUsageRawName(item))
      if (signals.speechHdTotal === null && isSpeechHdUsageName(name)) {
        signals.speechHdTotal = normalizedTotal
        continue
      }
      if (signals.image01Total === null && isImage01UsageName(name)) {
        signals.image01Total = normalizedTotal
        continue
      }
      if (signals.sessionTotal === null && isSessionUsageName(name)) {
        signals.sessionTotal = normalizedTotal
      }
    }

    if (signals.sessionTotal === null) signals.sessionTotal = fallbackSessionTotal
    return signals
  }

  function normalizeUsageName(value) {
    const raw = readString(value)
    if (!raw) return null
    return raw.replace(/\s+/g, " ").trim()
  }

  function classifyUsageEntry(item, endpointSelection, index) {
    const rawName = readUsageRawName(item)
    const name = normalizeUsageNameKey(rawName)

    if (endpointSelection !== "CN") {
      return { label: "Session", suffix: MODEL_CALLS_SUFFIX, isSession: true }
    }

    if (isSpeechHdUsageName(name)) {
      return { label: "Text to Speech HD", suffix: "chars", isSession: false }
    }
    if (isSpeechTurboUsageName(name)) {
      return { label: "Text to Speech Turbo", suffix: "chars", isSession: false }
    }
    if (isImage01UsageName(name)) {
      return { label: "image-01", suffix: "images", isSession: false }
    }
    if (name.includes("image generation")) {
      return { label: "Image Generation", suffix: "images", isSession: false }
    }
    if (isSessionUsageName(name)) {
      return { label: "Session", suffix: MODEL_CALLS_SUFFIX, isSession: true }
    }
    if (index === 0) {
      return { label: "Session", suffix: MODEL_CALLS_SUFFIX, isSession: true }
    }
    return {
      label: rawName || "Usage",
      suffix: "count",
      isSession: false,
    }
  }

  function epochToMs(epoch) {
    const n = readNumber(epoch)
    if (n === null) return null
    return Math.abs(n) < 1e10 ? n * 1000 : n
  }

  function inferRemainsMs(remainsRaw, endMs, nowMs) {
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

    // Coding Plan resets every 5h. Use that constraint before defaulting.
    const maxExpectedMs = CODING_PLAN_WINDOW_MS + CODING_PLAN_WINDOW_TOLERANCE_MS
    const secondsLooksValid = asSecondsMs <= maxExpectedMs
    const millisecondsLooksValid = asMillisecondsMs <= maxExpectedMs

    if (secondsLooksValid && !millisecondsLooksValid) return asSecondsMs
    if (millisecondsLooksValid && !secondsLooksValid) return asMillisecondsMs
    if (secondsLooksValid && millisecondsLooksValid) return asSecondsMs

    const secOverflow = Math.abs(asSecondsMs - maxExpectedMs)
    const msOverflow = Math.abs(asMillisecondsMs - maxExpectedMs)
    return secOverflow <= msOverflow ? asSecondsMs : asMillisecondsMs
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

  function parseModelRemainEntry(ctx, item, endpointSelection, index) {
    if (!item || typeof item !== "object") return null

    const usageMeta = classifyUsageEntry(item, endpointSelection, index)
    let total = readNumber(item.current_interval_total_count ?? item.currentIntervalTotalCount)
    if (total === null || total <= 0) return null

    const usageFieldCount = readNumber(item.current_interval_usage_count ?? item.currentIntervalUsageCount)
    const remainingCount = readNumber(
      item.current_interval_remaining_count ??
        item.currentIntervalRemainingCount ??
        item.current_interval_remains_count ??
        item.currentIntervalRemainsCount ??
        item.current_interval_remain_count ??
        item.currentIntervalRemainCount ??
        item.remaining_count ??
        item.remainingCount ??
        item.remains_count ??
        item.remainsCount ??
        item.remaining ??
        item.remains ??
        item.left_count ??
        item.leftCount
    )
    // MiniMax "coding_plan/remains" commonly returns remaining usage in current_interval_usage_count.
    const inferredRemainingCount = remainingCount !== null ? remainingCount : usageFieldCount
    const explicitUsed = readNumber(
      item.current_interval_used_count ??
        item.currentIntervalUsedCount ??
        item.used_count ??
        item.used
    )
    let used = explicitUsed

    if (used === null && inferredRemainingCount !== null) used = total - inferredRemainingCount
    if (used === null) return null

    if (used < 0) used = 0
    if (used > total) used = total

    const startMs = epochToMs(item.start_time ?? item.startTime)
    const endMs = epochToMs(item.end_time ?? item.endTime)
    const remainsRaw = readNumber(item.remains_time ?? item.remainsTime)
    const nowMs = Date.now()
    const remainsMs = inferRemainsMs(remainsRaw, endMs, nowMs)

    let resetsAt = endMs !== null ? ctx.util.toIso(endMs) : null
    if (!resetsAt && remainsMs !== null) {
      resetsAt = ctx.util.toIso(nowMs + remainsMs)
    }

    let periodDurationMs = null
    if (startMs !== null && endMs !== null && endMs > startMs) {
      periodDurationMs = endMs - startMs
    } else if (endpointSelection === "CN" && !usageMeta.isSession) {
      periodDurationMs = DAILY_WINDOW_MS
    }

    return {
      label: usageMeta.label,
      used,
      total,
      suffix: usageMeta.suffix,
      resetsAt,
      periodDurationMs,
    }
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

    const entries = []
    const seenLabels = Object.create(null)
    for (let i = 0; i < modelRemains.length; i += 1) {
      const entry = parseModelRemainEntry(ctx, modelRemains[i], endpointSelection, i)
      if (!entry) continue
      if (seenLabels[entry.label]) continue
      seenLabels[entry.label] = true
      entries.push(entry)
      if (endpointSelection !== "CN") break
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
    const inferredPlanName = inferPlanNameFromSignals(
      collectPlanInferenceSignals(modelRemains),
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
        used: Math.round(entry.used),
        limit: Math.round(entry.total),
        format: { kind: "count", suffix: entry.suffix },
      }
      if (entry.resetsAt) line.resetsAt = entry.resetsAt
      if (entry.periodDurationMs !== null) line.periodDurationMs = entry.periodDurationMs
      return ctx.line.progress(line)
    })

    const result = { lines }
    if (parsed.planName) {
      const regionLabel = successfulEndpoint === "CN" ? " (CN)" : " (GLOBAL)"
      result.plan = parsed.planName + regionLabel
    }
    return result
  }

  globalThis.__openusage_plugin = { id: "minimax", probe }
})()
