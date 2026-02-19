(function () {
  const PRIMARY_USAGE_URL = "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
  const FALLBACK_USAGE_URLS = [
    "https://api.minimax.io/v1/api/openplatform/coding_plan/remains",
    "https://api.minimax.io/v1/coding_plan/remains",
  ]
  const API_KEY_ENV_VARS = ["MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
  const CODING_PLAN_WINDOW_MS = 5 * 60 * 60 * 1000
  const CODING_PLAN_WINDOW_TOLERANCE_MS = 10 * 60 * 1000

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
    if (withoutPrefix) return withoutPrefix
    if (/coding\s+plan/i.test(compact)) return "Coding Plan"
    return compact
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

  function loadApiKey(ctx) {
    for (let i = 0; i < API_KEY_ENV_VARS.length; i += 1) {
      const name = API_KEY_ENV_VARS[i]
      let value = null
      try {
        value = ctx.host.env.get(name)
      } catch (e) {
        ctx.host.log.warn("env read failed for " + name + ": " + String(e))
      }
      const key = readString(value)
      if (key) {
        ctx.host.log.info("api key loaded from " + name)
        return key
      }
    }
    return null
  }

  function parsePayloadShape(ctx, payload) {
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
        throw "Session expired. Check your MiniMax API key."
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

    let chosen = modelRemains[0]
    for (let i = 0; i < modelRemains.length; i += 1) {
      const item = modelRemains[i]
      if (!item || typeof item !== "object") continue
      const total = readNumber(item.current_interval_total_count ?? item.currentIntervalTotalCount)
      if (total !== null && total > 0) {
        chosen = item
        break
      }
    }

    if (!chosen || typeof chosen !== "object") return null

    const total = readNumber(chosen.current_interval_total_count ?? chosen.currentIntervalTotalCount)
    if (total === null || total <= 0) return null

    const usageCount = readNumber(chosen.current_interval_usage_count ?? chosen.currentIntervalUsageCount)
    const remainingCount = readNumber(
      chosen.current_interval_remaining_count ??
        chosen.currentIntervalRemainingCount ??
        chosen.current_interval_remains_count ??
        chosen.currentIntervalRemainsCount ??
        chosen.remaining_count ??
        chosen.remainingCount ??
        chosen.remains_count ??
        chosen.remainsCount ??
        chosen.remaining ??
        chosen.remains ??
        chosen.left_count ??
        chosen.leftCount
    )
    const explicitUsed = readNumber(
      chosen.current_interval_used_count ??
        chosen.currentIntervalUsedCount ??
        chosen.used_count ??
        chosen.used
    )
    let used = explicitUsed

    if (used === null && usageCount !== null) used = usageCount
    if (used === null && remainingCount !== null) used = total - remainingCount
    if (used === null) return null
    if (used < 0) used = 0
    if (used > total) used = total

    const startMs = epochToMs(chosen.start_time ?? chosen.startTime)
    const endMs = epochToMs(chosen.end_time ?? chosen.endTime)
    const remainsRaw = readNumber(chosen.remains_time ?? chosen.remainsTime)
    const nowMs = Date.now()
    const remainsMs = inferRemainsMs(remainsRaw, endMs, nowMs)

    let resetsAt = endMs !== null ? ctx.util.toIso(endMs) : null
    if (!resetsAt && remainsMs !== null) {
      resetsAt = ctx.util.toIso(nowMs + remainsMs)
    }

    let periodDurationMs = null
    if (startMs !== null && endMs !== null && endMs > startMs) {
      periodDurationMs = endMs - startMs
    }

    const planName = normalizePlanName(pickFirstString([
      data.current_subscribe_title,
      data.plan_name,
      data.plan,
      data.current_plan_title,
      data.combo_title,
      payload.current_subscribe_title,
      payload.plan_name,
      payload.plan,
      chosen.model_name,
    ]))

    return {
      planName,
      used,
      total,
      resetsAt,
      periodDurationMs,
    }
  }

  function fetchUsagePayload(ctx, apiKey) {
    const urls = [PRIMARY_USAGE_URL].concat(FALLBACK_USAGE_URLS)
    let lastStatus = null
    let hadNetworkError = false

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
        throw "Session expired. Check your MiniMax API key."
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

    if (lastStatus !== null) throw "Request failed (HTTP " + lastStatus + "). Try again later."
    if (hadNetworkError) throw "Request failed. Check your connection."
    throw "Could not parse usage data."
  }

  function probe(ctx) {
    const apiKey = loadApiKey(ctx)
    if (!apiKey) throw "MiniMax API key missing. Set MINIMAX_API_KEY."

    const payload = fetchUsagePayload(ctx, apiKey)
    const parsed = parsePayloadShape(ctx, payload)
    if (!parsed) throw "Could not parse usage data."

    const line = {
      label: "Session",
      used: parsed.used,
      limit: parsed.total,
      format: { kind: "count", suffix: "prompts" },
    }
    if (parsed.resetsAt) line.resetsAt = parsed.resetsAt
    if (parsed.periodDurationMs !== null) line.periodDurationMs = parsed.periodDurationMs

    const result = { lines: [ctx.line.progress(line)] }
    if (parsed.planName) result.plan = parsed.planName
    return result
  }

  globalThis.__openusage_plugin = { id: "minimax", probe }
})()
