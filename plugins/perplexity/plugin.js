(function () {
  const PREFS_PATHS = [
    "~/Library/Containers/ai.perplexity.mac/Data/Library/Preferences/ai.perplexity.mac.plist",
    "~/Library/Containers/ai.perplexity.app/Data/Library/Preferences/ai.perplexity.app.plist",
  ]
  const CACHE_DB_PATHS = [
    "~/Library/Containers/ai.perplexity.mac/Data/Library/Caches/ai.perplexity.mac/Cache.db",
    "~/Library/Containers/ai.perplexity.app/Data/Library/Caches/ai.perplexity.app/Cache.db",
  ]
  const API_USER_URL = "https://www.perplexity.ai/api/user"
  const API_USER_LIKE = "(c.request_key LIKE '%/api/user%' OR c.request_key LIKE '%/p/api/v1/user%')"
  const PERPLEXITY_URL_LIKE = "(c.request_key LIKE '%perplexity.ai/%')"
  const NO_USAGE_MESSAGE = "Usage data unavailable. Open Perplexity app and run a search, then try again."
  const BASELINE_STATE_VERSION = 1

  function readPrefsRawValue(ctx, key) {
    if (!ctx.host.plist || typeof ctx.host.plist.readRaw !== "function") return null
    for (const path of PREFS_PATHS) {
      try {
        if (!ctx.host.fs.exists(path)) continue
        const value = ctx.host.plist.readRaw(path, key)
        if (typeof value === "string" && value.trim()) return value.trim()
      } catch (e) {
        ctx.host.log.warn("prefs raw read failed for " + key + " at " + path + ": " + String(e))
      }
    }
    return null
  }

  function loadPrefsText(ctx) {
    for (const path of PREFS_PATHS) {
      try {
        if (!ctx.host.fs.exists(path)) continue
        return ctx.host.fs.readText(path)
      } catch (e) {
        // Binary plist often fails UTF-8 decode in host fs.readText.
        ctx.host.log.warn("prefs read failed for " + path + ": " + String(e))
      }
    }
    return null
  }

  function extractTokenFromPrefs(text) {
    if (!text) return null
    const candidates = []
    const patterns = [
      /eyJ[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*){4}/g, // JWE (5 segments)
      /eyJ[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*){2}/g, // JWT (3 segments)
    ]
    for (const pattern of patterns) {
      const matches = String(text).match(pattern) || []
      for (const match of matches) {
        const cleaned = String(match).replace(/[^A-Za-z0-9._-]+$/g, "")
        if (cleaned.split(".").length >= 3) candidates.push(cleaned)
      }
    }
    if (candidates.length === 0) return null
    candidates.sort((a, b) => b.length - a.length)
    return candidates[0]
  }

  function extractUserSnapshotFromPrefs(ctx, text) {
    if (!text) return null

    function looksLikeSnapshot(value) {
      if (!value || typeof value !== "object") return false
      const hasRemaining = value.remainingUsage && typeof value.remainingUsage === "object"
      const hasSubscription = value.subscription && typeof value.subscription === "object"
      return hasRemaining || hasSubscription
    }

    const match = String(text).match(/\{\"isOrganizationAdmin\"[\s\S]*?\"disabledBackendModels\":\[\]\}/)
    if (match) {
      const parsed = ctx.util.tryParseJson(match[0])
      if (looksLikeSnapshot(parsed)) return parsed
    }

    // v5.1+ stores current_user__data as base64 in prefs.
    const b64Matches = String(text).match(/eyJ[A-Za-z0-9+/=]{120,}/g) || []
    for (const candidateRaw of b64Matches) {
      let candidate = String(candidateRaw).replace(/[^A-Za-z0-9+/=]/g, "")
      if (!candidate) continue
      const pad = candidate.length % 4
      if (pad !== 0) candidate += "=".repeat(4 - pad)

      try {
        const decoded = ctx.base64.decode(candidate)
        const parsed = ctx.util.tryParseJson(decoded)
        if (looksLikeSnapshot(parsed)) return parsed
      } catch {}
    }

    return null
  }

  function extractUserSnapshotFromRaw(ctx, raw) {
    if (!raw) return null
    const text = String(raw).trim()
    if (!text) return null

    const asJson = ctx.util.tryParseJson(text)
    if (asJson && typeof asJson === "object" && asJson.remainingUsage && typeof asJson.remainingUsage === "object") {
      return asJson
    }

    try {
      const decoded = ctx.base64.decode(text)
      const parsed = ctx.util.tryParseJson(decoded)
      if (parsed && typeof parsed === "object" && parsed.remainingUsage && typeof parsed.remainingUsage === "object") {
        return parsed
      }
    } catch {}

    return null
  }

  function queryRows(ctx, dbPath, sql, label) {
    try {
      const json = ctx.host.sqlite.query(dbPath, sql)
      const rows = ctx.util.tryParseJson(json)
      if (!Array.isArray(rows)) {
        ctx.host.log.warn(label + " sqlite query returned non-array")
        return []
      }
      return rows
    } catch (e) {
      ctx.host.log.warn(label + " sqlite query failed: " + String(e))
      return []
    }
  }

  function queryRowsAcrossCaches(ctx, sql, label) {
    const out = []
    for (const dbPath of CACHE_DB_PATHS) {
      if (!ctx.host.fs.exists(dbPath)) continue
      const rows = queryRows(ctx, dbPath, sql, label)
      for (const row of rows) out.push(row)
      if (out.length > 0) break
    }
    return out
  }

  function extractTokenFromRequestHex(hex) {
    if (!hex || typeof hex !== "string") return null
    const marker = "42656172657220" // "Bearer "
    const upper = hex.toUpperCase()
    const start = upper.indexOf(marker)
    if (start < 0) return null

    let token = ""
    for (let i = start + marker.length; i + 1 < upper.length; i += 2) {
      const byteHex = upper.slice(i, i + 2)
      const n = parseInt(byteHex, 16)
      if (!Number.isFinite(n)) break
      const ch = String.fromCharCode(n)
      if (!/[A-Za-z0-9._-]/.test(ch)) break
      token += ch
    }
    token = token.replace(/[^A-Za-z0-9._-]+$/g, "")
    if (token.split(".").length < 3) return null
    return token
  }

  function loadTokenFromCacheRequest(ctx) {
    const rows = queryRowsAcrossCaches(
      ctx,
      "SELECT hex(b.request_object) AS requestHex FROM cfurl_cache_blob_data b " +
        "JOIN cfurl_cache_response c ON c.entry_ID = b.entry_ID " +
        "WHERE " +
        PERPLEXITY_URL_LIKE +
        " ORDER BY c.time_stamp DESC LIMIT 20;",
      "token"
    )
    for (const row of rows) {
      const hex = row.requestHex || row.requesthex || row.request_object
      const token = extractTokenFromRequestHex(hex)
      if (token) return token
    }
    return null
  }

  function loadCachedApiUser(ctx) {
    const strictRows = queryRowsAcrossCaches(
      ctx,
      "SELECT CAST(r.receiver_data AS TEXT) AS body FROM cfurl_cache_response c " +
        "JOIN cfurl_cache_receiver_data r ON r.entry_ID = c.entry_ID " +
        "WHERE " +
        API_USER_LIKE +
        " ORDER BY c.time_stamp DESC LIMIT 20;",
      "cached user"
    )
    for (const row of strictRows) {
      const parsed = ctx.util.tryParseJson(row.body)
      if (parsed && typeof parsed === "object") return parsed
    }

    const broadRows = queryRowsAcrossCaches(
      ctx,
      "SELECT CAST(r.receiver_data AS TEXT) AS body FROM cfurl_cache_response c " +
        "JOIN cfurl_cache_receiver_data r ON r.entry_ID = c.entry_ID " +
        "WHERE " +
        PERPLEXITY_URL_LIKE +
        " ORDER BY c.time_stamp DESC LIMIT 120;",
      "cached user broad"
    )
    for (const row of broadRows) {
      const parsed = ctx.util.tryParseJson(row.body)
      if (!parsed || typeof parsed !== "object") continue

      const hasRemaining = parsed.remainingUsage && typeof parsed.remainingUsage === "object"
      const hasSubscription =
        typeof parsed.subscription_tier === "string" ||
        typeof parsed.payment_tier === "string" ||
        (parsed.subscription && typeof parsed.subscription === "object")
      const looksLikeUser = typeof parsed.id === "string" || typeof parsed.email === "string"

      if (hasRemaining || (hasSubscription && looksLikeUser)) return parsed
    }
    return null
  }

  function collectRemainingHighWater(target, value) {
    if (!target || typeof target !== "object") return
    if (!value || typeof value !== "object") return

    const mappings = [
      { key: "pro", fields: ["remaining_pro", "pro_remaining", "remainingPro"] },
      { key: "research", fields: ["remaining_research", "research_remaining", "remainingResearch"] },
      { key: "labs", fields: ["remaining_labs", "labs_remaining", "remainingLabs"] },
    ]

    for (const mapping of mappings) {
      for (const field of mapping.fields) {
        const n = Number(value[field])
        if (!Number.isFinite(n) || n <= 0) continue
        if (target[mapping.key] === null || n > target[mapping.key]) {
          target[mapping.key] = n
        }
      }
    }
  }

  function loadRemainingHighWaterFromCache(ctx) {
    const rows = queryRowsAcrossCaches(
      ctx,
      "SELECT CAST(r.receiver_data AS TEXT) AS body FROM cfurl_cache_response c " +
        "JOIN cfurl_cache_receiver_data r ON r.entry_ID = c.entry_ID " +
        "WHERE " +
        PERPLEXITY_URL_LIKE +
        " ORDER BY c.time_stamp DESC LIMIT 300;",
      "usage high-water"
    )

    const highWater = { pro: null, research: null, labs: null }
    for (const row of rows) {
      const parsed = ctx.util.tryParseJson(row.body)
      if (!parsed || typeof parsed !== "object") continue
      collectRemainingHighWater(highWater, parsed)
      collectRemainingHighWater(highWater, parsed.remainingUsage)
    }
    return highWater
  }

  function makeEmptyMetricBaseline() {
    return {
      baselineRemaining: null,
      lastRemaining: null,
      updatedAt: null,
    }
  }

  function makeEmptyBaselineMetrics() {
    return {
      pro: makeEmptyMetricBaseline(),
      research: makeEmptyMetricBaseline(),
      labs: makeEmptyMetricBaseline(),
    }
  }

  function makeDefaultBaselineState() {
    return {
      version: BASELINE_STATE_VERSION,
      accountKey: null,
      planTier: null,
      metrics: makeEmptyBaselineMetrics(),
    }
  }

  function normalizeMetricBaseline(value) {
    const out = makeEmptyMetricBaseline()
    if (!value || typeof value !== "object") return out

    const baseline = Number(value.baselineRemaining)
    if (Number.isFinite(baseline) && baseline >= 0) out.baselineRemaining = baseline

    const lastRemaining = Number(value.lastRemaining)
    if (Number.isFinite(lastRemaining) && lastRemaining >= 0) out.lastRemaining = lastRemaining

    if (typeof value.updatedAt === "string" && value.updatedAt.trim()) {
      out.updatedAt = value.updatedAt.trim()
    }

    return out
  }

  function normalizeBaselineState(parsed) {
    const out = makeDefaultBaselineState()
    if (!parsed || typeof parsed !== "object") return out

    if (typeof parsed.accountKey === "string" && parsed.accountKey.trim()) {
      out.accountKey = parsed.accountKey.trim()
    }
    if (typeof parsed.planTier === "string" && parsed.planTier.trim()) {
      out.planTier = parsed.planTier.trim()
    }

    const metrics = parsed.metrics && typeof parsed.metrics === "object" ? parsed.metrics : null
    if (metrics) {
      out.metrics.pro = normalizeMetricBaseline(metrics.pro)
      out.metrics.research = normalizeMetricBaseline(metrics.research)
      out.metrics.labs = normalizeMetricBaseline(metrics.labs)
    }

    return out
  }

  function getBaselineStatePath(ctx) {
    return ctx.app.pluginDataDir + "/usage-baseline.json"
  }

  function loadUsageBaselineState(ctx) {
    const path = getBaselineStatePath(ctx)
    try {
      if (!ctx.host.fs.exists(path)) return makeDefaultBaselineState()
      const text = ctx.host.fs.readText(path)
      const parsed = ctx.util.tryParseJson(text)
      if (!parsed || typeof parsed !== "object") {
        ctx.host.log.warn("usage baseline state invalid json; resetting")
        return makeDefaultBaselineState()
      }
      return normalizeBaselineState(parsed)
    } catch (e) {
      ctx.host.log.warn("usage baseline state read failed: " + String(e))
      return makeDefaultBaselineState()
    }
  }

  function saveUsageBaselineState(ctx, state) {
    const path = getBaselineStatePath(ctx)
    const payload = {
      version: BASELINE_STATE_VERSION,
      accountKey: state.accountKey || null,
      planTier: state.planTier || null,
      metrics: {
        pro: normalizeMetricBaseline(state.metrics && state.metrics.pro),
        research: normalizeMetricBaseline(state.metrics && state.metrics.research),
        labs: normalizeMetricBaseline(state.metrics && state.metrics.labs),
      },
    }
    try {
      ctx.host.fs.writeText(path, JSON.stringify(payload, null, 2))
    } catch (e) {
      ctx.host.log.warn("usage baseline state write failed: " + String(e))
    }
  }

  function resetBaselineMetrics(state) {
    state.metrics = makeEmptyBaselineMetrics()
  }

  function prepareBaselineStateContext(state, accountKey, planTier) {
    let changed = false
    const nextAccountKey = typeof accountKey === "string" && accountKey.trim() ? accountKey.trim() : null
    const nextPlanTier = typeof planTier === "string" && planTier.trim() ? planTier.trim() : null

    const accountChanged =
      nextAccountKey !== null &&
      typeof state.accountKey === "string" &&
      state.accountKey !== nextAccountKey

    const planChanged =
      nextPlanTier !== null &&
      typeof state.planTier === "string" &&
      state.planTier !== nextPlanTier

    if (accountChanged || planChanged) {
      resetBaselineMetrics(state)
      changed = true
    }

    if (nextAccountKey !== null && state.accountKey !== nextAccountKey) {
      state.accountKey = nextAccountKey
      changed = true
    }
    if (nextPlanTier !== null && state.planTier !== nextPlanTier) {
      state.planTier = nextPlanTier
      changed = true
    }

    return changed
  }

  function loadCredentials(ctx) {
    const rawUserData = readPrefsRawValue(ctx, "current_user__data")
    const snapshotFromRaw = extractUserSnapshotFromRaw(ctx, rawUserData)

    const prefsText = loadPrefsText(ctx)
    const snapshot = snapshotFromRaw || extractUserSnapshotFromPrefs(ctx, prefsText)
    const cachedUser = loadCachedApiUser(ctx)
    const tokenRaw = readPrefsRawValue(ctx, "authToken")
    const tokenFromRaw = extractTokenFromPrefs(tokenRaw)
    if (tokenFromRaw) {
      ctx.host.log.info("auth token loaded from prefs raw")
      return { token: tokenFromRaw, snapshot, cachedUser, source: "prefs_raw" }
    }

    const tokenFromPrefs = extractTokenFromPrefs(prefsText)
    if (tokenFromPrefs) {
      ctx.host.log.info("auth token loaded from prefs")
      return { token: tokenFromPrefs, snapshot, cachedUser, source: "prefs" }
    }

    const tokenFromCache = loadTokenFromCacheRequest(ctx)
    if (tokenFromCache) {
      ctx.host.log.info("auth token loaded from cache request")
      return { token: tokenFromCache, snapshot, cachedUser, source: "cache" }
    }

    return { token: null, snapshot, cachedUser, source: null }
  }

  function fetchApiUser(ctx, token) {
    return ctx.util.request({
      method: "GET",
      url: API_USER_URL,
      headers: {
        Authorization: "Bearer " + token,
        Accept: "application/json",
        "X-Client-Name": "Perplexity-Mac",
        "X-App-ApiVersion": "2.17",
        "X-App-ApiClient": "macos",
        "X-Client-Env": "production",
        "User-Agent": "OpenUsage",
      },
      timeoutMs: 10000,
    })
  }

  function pickNumberFromSources(sources, keys) {
    for (const source of sources) {
      if (!source || typeof source !== "object") continue
      for (const key of keys) {
        const value = source[key]
        const n = Number(value)
        if (Number.isFinite(n)) return n
      }
    }
    return null
  }

  function pickStringFromSources(sources, keys) {
    for (const source of sources) {
      if (!source || typeof source !== "object") continue
      for (const key of keys) {
        const value = source[key]
        if (typeof value === "string" && value.trim()) return value.trim()
      }
    }
    return null
  }

  function pickPlan(ctx, liveData, snapshot) {
    const subscriptionLive = liveData && typeof liveData.subscription === "object" ? liveData.subscription : null
    const subscriptionSnapshot =
      snapshot && typeof snapshot.subscription === "object" ? snapshot.subscription : null

    const planRaw = pickStringFromSources(
      [liveData, subscriptionLive, snapshot, subscriptionSnapshot],
      [
        "subscription_tier",
        "payment_tier",
        "tier",
        "paymentTier",
      ]
    )
    if (!planRaw) return null
    if (planRaw.toLowerCase() === "none") return "Free"
    const label = ctx.fmt.planLabel(planRaw)
    return label || null
  }

  function hasLocalSession(snapshot) {
    if (!snapshot || typeof snapshot !== "object") return false
    if (typeof snapshot.id === "string" && snapshot.id.trim()) return true
    if (typeof snapshot.email === "string" && snapshot.email.trim()) return true
    if (snapshot.subscription && typeof snapshot.subscription === "object") return true
    return false
  }

  function inferPlanTier(liveData, snapshot) {
    const subscriptionLive = liveData && typeof liveData.subscription === "object" ? liveData.subscription : null
    const subscriptionSnapshot =
      snapshot && typeof snapshot.subscription === "object" ? snapshot.subscription : null
    const tier = pickStringFromSources(
      [liveData, subscriptionLive, snapshot, subscriptionSnapshot],
      ["subscription_tier", "payment_tier", "tier", "paymentTier"]
    )
    return tier ? tier.toLowerCase() : null
  }

  function isFreeLikeTier(tier) {
    if (!tier) return false
    return (
      tier === "none" ||
      tier === "free" ||
      tier === "free_with_pm" ||
      tier === "basic"
    )
  }

  function isProLikeTier(tier) {
    if (!tier) return false
    return tier === "pro" || tier === "professional" || tier === "pro_with_pm"
  }

  function getTierDefaultLimit(metricKey, tier) {
    if (!isProLikeTier(tier)) return null
    if (metricKey === "pro") return 600
    if (metricKey === "research") return 20
    if (metricKey === "labs") return 25
    return null
  }

  function appendUsageLines(ctx, liveData, snapshot, lines, usageHighWater, baselineState) {
    let stateChanged = false
    const liveRemaining =
      liveData && typeof liveData.remainingUsage === "object" ? liveData.remainingUsage : null
    const snapshotRemaining =
      snapshot && typeof snapshot.remainingUsage === "object" ? snapshot.remainingUsage : null

    const sources = [liveRemaining, liveData, snapshotRemaining, snapshot]
    const metrics = [
      {
        label: "Pro",
        highWaterKey: "pro",
        remainingKeys: ["remaining_pro", "pro_remaining", "remainingPro"],
        limitKeys: ["pro_limit", "limit_pro", "proLimit", "max_pro", "total_pro"],
        resetKeys: ["pro_resets_at", "pro_reset_at", "resets_at"],
      },
      {
        label: "Research",
        highWaterKey: "research",
        remainingKeys: ["remaining_research", "research_remaining", "remainingResearch"],
        limitKeys: ["research_limit", "limit_research", "researchLimit", "max_research", "total_research"],
        resetKeys: ["research_resets_at", "research_reset_at", "resets_at"],
      },
      {
        label: "Labs",
        highWaterKey: "labs",
        remainingKeys: ["remaining_labs", "labs_remaining", "remainingLabs"],
        limitKeys: ["labs_limit", "limit_labs", "labsLimit", "max_labs", "total_labs"],
        resetKeys: ["labs_resets_at", "labs_reset_at", "resets_at"],
      },
    ]

    const tier = inferPlanTier(liveData, snapshot)
    const allowUploadLimitFallback = isFreeLikeTier(tier)
    const nowIso =
      typeof ctx.nowIso === "string" && ctx.nowIso.trim()
        ? ctx.nowIso.trim()
        : new Date().toISOString()

    for (const metric of metrics) {
      const remaining = pickNumberFromSources(sources, metric.remainingKeys)
      if (remaining === null || remaining < 0) continue

      let metricBaseline = null
      if (baselineState && baselineState.metrics && typeof baselineState.metrics === "object") {
        metricBaseline = baselineState.metrics[metric.highWaterKey]
        if (!metricBaseline || typeof metricBaseline !== "object") {
          metricBaseline = makeEmptyMetricBaseline()
          baselineState.metrics[metric.highWaterKey] = metricBaseline
          stateChanged = true
        }
      }

      let limit = pickNumberFromSources(sources, metric.limitKeys)
      if ((limit === null || limit <= 0) && metric.label === "Pro" && allowUploadLimitFallback) {
        const uploadLimit = pickNumberFromSources(sources, ["uploadLimit"])
        if (uploadLimit !== null && uploadLimit > 0) {
          limit = uploadLimit
        }
      }

      const resetsAt = ctx.util.toIso(pickStringFromSources(sources, metric.resetKeys))
      const tierDefaultLimitRaw = getTierDefaultLimit(metric.highWaterKey, tier)
      const tierDefaultLimit =
        Number.isFinite(Number(tierDefaultLimitRaw)) && Number(tierDefaultLimitRaw) > 0
          ? Number(tierDefaultLimitRaw)
          : null

      let progressLimit = null
      let used = 0
      const inferredHighWater =
        usageHighWater && Number.isFinite(Number(usageHighWater[metric.highWaterKey]))
          ? Number(usageHighWater[metric.highWaterKey])
          : null
      const persistedBaseline =
        metricBaseline && Number.isFinite(Number(metricBaseline.baselineRemaining))
          ? Number(metricBaseline.baselineRemaining)
          : null
      const explicitLimitValid = limit !== null && limit > 0 && limit >= remaining

      if (explicitLimitValid) {
        progressLimit = limit
      } else {
        const inferredCaps = []
        if (tierDefaultLimit !== null && tierDefaultLimit >= remaining) inferredCaps.push(tierDefaultLimit)
        if (persistedBaseline !== null && persistedBaseline > 0) inferredCaps.push(persistedBaseline)
        if (inferredHighWater !== null && inferredHighWater > 0) inferredCaps.push(inferredHighWater)
        if (remaining > 0) inferredCaps.push(remaining)
        if (inferredCaps.length > 0) progressLimit = Math.max(...inferredCaps)
      }

      if (progressLimit !== null && progressLimit > 0) {
        used = Math.max(0, Math.min(progressLimit, progressLimit - remaining))

        if (metricBaseline) {
          if (metricBaseline.baselineRemaining !== progressLimit) {
            metricBaseline.baselineRemaining = progressLimit
            stateChanged = true
          }
          if (metricBaseline.lastRemaining !== remaining) {
            metricBaseline.lastRemaining = remaining
            stateChanged = true
          }
          if (metricBaseline.updatedAt !== nowIso) {
            metricBaseline.updatedAt = nowIso
            stateChanged = true
          }
        }
      }

      if (progressLimit !== null && progressLimit > 0) {
        lines.push(
          ctx.line.progress({
            label: metric.label,
            used: used,
            limit: progressLimit,
            format: { kind: "count", suffix: "uses" },
            resetsAt: resetsAt || undefined,
          })
        )
      } else {
        lines.push(
          ctx.line.text({
            label: metric.label,
            value: String(Math.max(0, Math.round(remaining))) + " left",
          })
        )
      }
    }

    return stateChanged
  }

  function probe(ctx) {
    const creds = loadCredentials(ctx)
    const usageHighWater = loadRemainingHighWaterFromCache(ctx)
    const baselineState = loadUsageBaselineState(ctx)
    let baselineStateChanged = false

    const contextAccountKey =
      pickStringFromSources([creds.snapshot, creds.cachedUser], ["id", "email"]) || null
    const contextPlanTier =
      inferPlanTier(creds.snapshot, creds.snapshot) ||
      inferPlanTier(creds.cachedUser, creds.snapshot) ||
      null
    baselineStateChanged =
      prepareBaselineStateContext(baselineState, contextAccountKey, contextPlanTier) ||
      baselineStateChanged

    const snapshotLines = []
    baselineStateChanged =
      appendUsageLines(
        ctx,
        creds.snapshot,
        creds.snapshot,
        snapshotLines,
        usageHighWater,
        baselineState
      ) || baselineStateChanged
    if (snapshotLines.length > 0) {
      if (baselineStateChanged) saveUsageBaselineState(ctx, baselineState)
      const localPlan = pickPlan(ctx, creds.snapshot, creds.snapshot)
      return { plan: localPlan || undefined, lines: snapshotLines }
    }

    const hasSnapshotSession = hasLocalSession(creds.snapshot)

    if (!creds.token) {
      if (hasSnapshotSession) {
        if (baselineStateChanged) saveUsageBaselineState(ctx, baselineState)
        throw NO_USAGE_MESSAGE
      }
      ctx.host.log.error("probe failed: no Perplexity auth token in local app session")
      throw "Not logged in. Sign in via Perplexity app."
    }

    const cachedLines = []
    baselineStateChanged =
      appendUsageLines(
        ctx,
        creds.cachedUser,
        creds.snapshot,
        cachedLines,
        usageHighWater,
        baselineState
      ) || baselineStateChanged
    if (cachedLines.length > 0) {
      if (baselineStateChanged) saveUsageBaselineState(ctx, baselineState)
      const cachedPlan = pickPlan(ctx, creds.cachedUser || creds.snapshot, creds.snapshot)
      return { plan: cachedPlan || undefined, lines: cachedLines }
    }

    let resp
    try {
      resp = fetchApiUser(ctx, creds.token)
    } catch (e) {
      ctx.host.log.error("usage request failed: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      ctx.host.log.error("usage auth failure: status=" + resp.status)
      if (hasSnapshotSession) {
        throw NO_USAGE_MESSAGE
      }
      throw "Token expired. Sign in via Perplexity app."
    }
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.error("usage request failed: status=" + resp.status)
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    const liveData = ctx.util.tryParseJson(resp.bodyText)
    if (liveData === null) {
      throw "Usage response invalid. Try again later."
    }
    const liveAccountKey = pickStringFromSources([liveData, creds.snapshot, creds.cachedUser], ["id", "email"]) || null
    const livePlanTier = inferPlanTier(liveData, creds.snapshot) || null
    baselineStateChanged =
      prepareBaselineStateContext(baselineState, liveAccountKey, livePlanTier) ||
      baselineStateChanged

    const cachedData = creds.cachedUser || loadCachedApiUser(ctx)
    const lines = []
    baselineStateChanged =
      appendUsageLines(
        ctx,
        liveData,
        creds.snapshot,
        lines,
        usageHighWater,
        baselineState
      ) || baselineStateChanged

    if (lines.length === 0) {
      baselineStateChanged =
        appendUsageLines(
          ctx,
          cachedData,
          creds.snapshot,
          lines,
          usageHighWater,
          baselineState
        ) || baselineStateChanged
    }

    if (lines.length === 0) {
      if (baselineStateChanged) saveUsageBaselineState(ctx, baselineState)
      throw NO_USAGE_MESSAGE
    }

    if (baselineStateChanged) saveUsageBaselineState(ctx, baselineState)
    const plan = pickPlan(ctx, liveData, creds.snapshot)
    return { plan: plan || undefined, lines }
  }

  globalThis.__openusage_plugin = { id: "perplexity", probe }
})()
