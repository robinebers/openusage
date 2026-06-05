(function () {
  const AUTH_V2_PATH = "~/.factory/auth.v2.file"
  const AUTH_V2_KEY_PATH = "~/.factory/auth.v2.key"
  const AUTH_PATHS = ["~/.factory/auth.encrypted", "~/.factory/auth.json"]
  const KEYCHAIN_SERVICES = ["Factory Token", "Factory token", "Factory Auth", "Droid Auth"]
  const WORKOS_CLIENT_ID = "client_01HNM792M5G5G1A2THWPXKFMXB"
  const WORKOS_AUTH_URL = "https://api.workos.com/user_management/authenticate"
  const APP_URL = "https://app.factory.ai"
  const USAGE_URL = "https://api.factory.ai/api/organization/subscription/usage"
  const BILLING_LIMITS_URL = "https://api.factory.ai/api/billing/limits"
  const COMPUTE_USAGE_URL = "https://api.factory.ai/api/organization/compute-usage"
  const TOKEN_REFRESH_THRESHOLD_MS = 24 * 60 * 60 * 1000 // 24 hours before expiry

  function decodeHexUtf8(hex) {
    try {
      const bytes = []
      for (let i = 0; i < hex.length; i += 2) {
        bytes.push(parseInt(hex.slice(i, i + 2), 16))
      }

      if (typeof TextDecoder !== "undefined") {
        try {
          return new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(bytes))
        } catch {}
      }

      let escaped = ""
      for (const b of bytes) {
        const h = b.toString(16)
        escaped += "%" + (h.length === 1 ? "0" + h : h)
      }
      return decodeURIComponent(escaped)
    } catch {
      return null
    }
  }

  function tryParseAuthJson(ctx, text) {
    if (!text) return null
    const parsed = ctx.util.tryParseJson(text)
    if (parsed !== null) return parsed

    // Some keychain payloads can be returned as hex-encoded UTF-8 bytes.
    let hex = String(text).trim()
    if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.slice(2)
    if (!hex || hex.length % 2 !== 0) return null
    if (!/^[0-9a-fA-F]+$/.test(hex)) return null

    const decoded = decodeHexUtf8(hex)
    if (!decoded) return null
    return ctx.util.tryParseJson(decoded)
  }

  function looksLikeJwt(value) {
    return /^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$/.test(value)
  }

  function normalizeAuthPayload(raw, opts) {
    const allowPartial = Boolean(opts && opts.allowPartial)
    if (!raw || typeof raw !== "object") return null

    const accessToken =
      raw.access_token ||
      raw.accessToken ||
      (raw.tokens && (raw.tokens.access_token || raw.tokens.accessToken))

    const refreshToken =
      raw.refresh_token ||
      raw.refreshToken ||
      (raw.tokens && (raw.tokens.refresh_token || raw.tokens.refreshToken))

    const hasAccess = typeof accessToken === "string" && accessToken
    const hasRefresh = typeof refreshToken === "string" && refreshToken
    if (!hasAccess && !(allowPartial && hasRefresh)) return null

    return {
      access_token: hasAccess ? accessToken : null,
      refresh_token: hasRefresh ? refreshToken : null,
    }
  }

  function parseAuthPayload(ctx, rawText, opts) {
    const parsed = tryParseAuthJson(ctx, rawText)
    const normalized = normalizeAuthPayload(parsed, opts)
    if (normalized) return normalized

    if (typeof parsed === "string" && looksLikeJwt(parsed)) {
      return { access_token: parsed, refresh_token: null }
    }

    const direct = String(rawText || "").trim()
    if (looksLikeJwt(direct)) {
      return { access_token: direct, refresh_token: null }
    }

    return null
  }

  function loadAuthFromV2File(ctx) {
    if (!ctx.host.crypto || typeof ctx.host.crypto.decryptAes256Gcm !== "function") {
      return null
    }
    if (!ctx.host.fs.exists(AUTH_V2_PATH) || !ctx.host.fs.exists(AUTH_V2_KEY_PATH)) {
      return null
    }

    try {
      const envelope = ctx.host.fs.readText(AUTH_V2_PATH)
      const key = ctx.host.fs.readText(AUTH_V2_KEY_PATH)
      const decrypted = ctx.host.crypto.decryptAes256Gcm(envelope, key)
      const auth = parseAuthPayload(ctx, decrypted, { allowPartial: true })
      if (!auth) {
        ctx.host.log.warn("auth file exists but has no valid auth payload: " + AUTH_V2_PATH)
        return null
      }
      ctx.host.log.info("auth loaded from file: " + AUTH_V2_PATH)
      return {
        auth,
        source: "file-v2",
        authPath: AUTH_V2_PATH,
        authKey: key,
        keychainService: null,
      }
    } catch (e) {
      ctx.host.log.warn("auth file read failed: " + String(e))
      return null
    }
  }

  function loadAuthFromFiles(ctx) {
    const v2Auth = loadAuthFromV2File(ctx)
    if (v2Auth) return v2Auth

    for (const authPath of AUTH_PATHS) {
      if (!ctx.host.fs.exists(authPath)) continue

      try {
        const text = ctx.host.fs.readText(authPath)
        const auth = parseAuthPayload(ctx, text, { allowPartial: true })
        if (!auth) {
          ctx.host.log.warn("auth file exists but has no valid auth payload: " + authPath)
          continue
        }
        ctx.host.log.info("auth loaded from file: " + authPath)
        return { auth, source: "file", authPath, keychainService: null }
      } catch (e) {
        ctx.host.log.warn("auth file read failed: " + String(e))
      }
    }

    return null
  }

  function loadAuthFromKeychain(ctx) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readGenericPassword !== "function") {
      return null
    }

    for (const service of KEYCHAIN_SERVICES) {
      try {
        const value = ctx.host.keychain.readGenericPassword(service)
        if (!value) continue

        const auth = parseAuthPayload(ctx, value)
        if (!auth) {
          ctx.host.log.warn("keychain has data but no valid auth payload: " + service)
          continue
        }

        ctx.host.log.info("auth loaded from keychain: " + service)
        return { auth, source: "keychain", authPath: null, keychainService: service }
      } catch (e) {
        ctx.host.log.info("keychain read failed (may not exist): " + String(e))
      }
    }

    return null
  }

  function loadAuth(ctx) {
    const fileAuth = loadAuthFromFiles(ctx)
    if (fileAuth) return fileAuth

    const keychainAuth = loadAuthFromKeychain(ctx)
    if (keychainAuth) return keychainAuth

    if (!ctx.host.fs.exists(AUTH_V2_PATH)) {
      ctx.host.log.warn("auth file not found: " + AUTH_V2_PATH)
    }
    if (!ctx.host.fs.exists(AUTH_V2_KEY_PATH)) {
      ctx.host.log.warn("auth file not found: " + AUTH_V2_KEY_PATH)
    }
    for (const authPath of AUTH_PATHS) {
      if (!ctx.host.fs.exists(authPath)) {
        ctx.host.log.warn("auth file not found: " + authPath)
      }
    }

    return null
  }

  function saveAuth(ctx, authState) {
    const auth = authState && authState.auth ? authState.auth : null
    if (!auth) return false

    try {
      if (authState.source === "file-v2" && authState.authPath && authState.authKey) {
        if (!ctx.host.crypto || typeof ctx.host.crypto.encryptAes256Gcm !== "function") {
          ctx.host.log.warn("auth persistence skipped: unsupported source " + authState.source)
          return false
        }
        const envelope = ctx.host.crypto.encryptAes256Gcm(JSON.stringify(auth, null, 2), authState.authKey)
        ctx.host.fs.writeText(authState.authPath, envelope)
        ctx.host.log.info("auth file updated: " + authState.authPath)
        return true
      }

      if (authState.source === "file" && authState.authPath) {
        ctx.host.fs.writeText(authState.authPath, JSON.stringify(auth, null, 2))
        ctx.host.log.info("auth file updated: " + authState.authPath)
        return true
      }

      if (
        authState.source === "keychain" &&
        authState.keychainService &&
        ctx.host.keychain &&
        typeof ctx.host.keychain.writeGenericPassword === "function"
      ) {
        ctx.host.keychain.writeGenericPassword(authState.keychainService, JSON.stringify(auth))
        ctx.host.log.info("auth keychain item updated: " + authState.keychainService)
        return true
      }

      ctx.host.log.warn("auth persistence skipped: unsupported source")
      return false
    } catch (e) {
      ctx.host.log.warn("failed to save auth: " + String(e))
      return false
    }
  }

  function getAccessTokenExpiryMs(ctx, accessToken) {
    const payload = ctx.jwt.decodePayload(accessToken)
    return payload && typeof payload.exp === "number" ? payload.exp * 1000 : null
  }

  function needsRefresh(ctx, accessToken, nowMs) {
    return ctx.util.needsRefreshByExpiry({
      nowMs,
      expiresAtMs: getAccessTokenExpiryMs(ctx, accessToken),
      bufferMs: TOKEN_REFRESH_THRESHOLD_MS,
    })
  }

  function canUseExistingAccessToken(ctx, accessToken, nowMs) {
    const expiresAtMs = getAccessTokenExpiryMs(ctx, accessToken)
    return typeof expiresAtMs === "number" && nowMs < expiresAtMs
  }

  function getUserIdFromAccessToken(ctx, accessToken) {
    const payload = ctx.jwt.decodePayload(accessToken)
    if (!payload || typeof payload !== "object") return null
    const rawUserId = payload.sub || payload.user_id || payload.userId
    if (typeof rawUserId !== "string") return null
    const userId = rawUserId.trim()
    return userId || null
  }

  function buildUsageHeaders(accessToken) {
    return {
      Authorization: "Bearer " + accessToken,
      "Content-Type": "application/json",
      Accept: "application/json",
      "User-Agent": "OpenUsage",
      Origin: APP_URL,
      Referer: APP_URL + "/",
      "x-factory-client": "web-app",
    }
  }

  function buildUsagePayload(ctx, accessToken) {
    const userId = getUserIdFromAccessToken(ctx, accessToken)
    const body = { useCache: true }
    if (userId) body.userId = userId
    return body
  }

  function buildUsageGetUrl(body) {
    const params = ["useCache=" + encodeURIComponent(String(body.useCache))]
    if (typeof body.userId === "string" && body.userId) {
      params.push("userId=" + encodeURIComponent(body.userId))
    }
    return USAGE_URL + "?" + params.join("&")
  }

  function refreshToken(ctx, authState) {
    const auth = authState.auth
    if (!auth.refresh_token) {
      ctx.host.log.warn("refresh skipped: no refresh token")
      return null
    }

    ctx.host.log.info("attempting token refresh via WorkOS")
    try {
      const resp = ctx.util.request({
        method: "POST",
        url: WORKOS_AUTH_URL,
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        bodyText:
          "grant_type=refresh_token" +
          "&refresh_token=" + encodeURIComponent(auth.refresh_token) +
          "&client_id=" + encodeURIComponent(WORKOS_CLIENT_ID),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        ctx.host.log.error("refresh failed: status=" + resp.status)
        throw "Session expired. Run `droid` to log in again."
      }
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("refresh returned unexpected status: " + resp.status)
        return null
      }

      const body = ctx.util.tryParseJson(resp.bodyText)
      if (!body) {
        ctx.host.log.warn("refresh response not valid JSON")
        return null
      }
      const newAccessToken = body.access_token
      if (!newAccessToken) {
        ctx.host.log.warn("refresh response missing access_token")
        return null
      }

      // Update auth object with new tokens
      auth.access_token = newAccessToken
      if (body.refresh_token) {
        auth.refresh_token = body.refresh_token
      }

      // Save updated auth
      saveAuth(ctx, authState)
      ctx.host.log.info("refresh succeeded")

      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("refresh exception: " + String(e))
      return null
    }
  }

  function fetchUsage(ctx, accessToken) {
    const body = buildUsagePayload(ctx, accessToken)
    var resp = ctx.util.request({
      method: "POST",
      url: USAGE_URL,
      headers: buildUsageHeaders(accessToken),
      bodyText: JSON.stringify(body),
      timeoutMs: 10000,
    })
    if (resp.status === 405) {
      ctx.host.log.info("POST returned 405, retrying with GET")
      resp = ctx.util.request({
        method: "GET",
        url: buildUsageGetUrl(body),
        headers: buildUsageHeaders(accessToken),
        timeoutMs: 10000,
      })
    }
    return resp
  }

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
  }

  function asNumber(value) {
    if (typeof value === "number" && Number.isFinite(value)) return value
    if (typeof value === "string") {
      const trimmed = value.trim().replace(/%$/, "")
      if (!trimmed) return null
      const parsed = Number(trimmed)
      return Number.isFinite(parsed) ? parsed : null
    }
    return null
  }

  function firstValue(source, keys) {
    if (!isObject(source)) return undefined
    for (const key of keys) {
      if (source[key] !== undefined && source[key] !== null) return source[key]
    }
    return undefined
  }

  function firstNumber(source, keys) {
    return asNumber(firstValue(source, keys))
  }

  function firstObject() {
    for (let i = 0; i < arguments.length; i += 1) {
      if (isObject(arguments[i])) return arguments[i]
    }
    return null
  }

  function requestGetJson(ctx, accessToken, url, label) {
    try {
      const resp = ctx.util.request({
        method: "GET",
        url,
        headers: buildUsageHeaders(accessToken),
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn(label + " request failed: status=" + resp.status)
        return null
      }
      const parsed = ctx.util.tryParseJson(resp.bodyText)
      if (!isObject(parsed)) {
        ctx.host.log.warn(label + " response invalid JSON")
        return null
      }
      return parsed
    } catch (e) {
      ctx.host.log.warn(label + " request exception: " + String(e))
      return null
    }
  }

  function droidCoreConfig(usage) {
    return firstObject(
      usage.droidCore,
      usage.droid_core,
      usage.models && usage.models.droidCore,
      usage.modelConfiguration && usage.modelConfiguration.droidCore,
    )
  }

  function hasExtendedUsageFields(usage) {
    if (!isObject(usage)) return false
    return Boolean(firstObject(
      usage.standardUsage,
      usage.standardLimits,
      usage.usageLimits,
      usage.limits,
      usage.extraUsage,
      usage.extra_usage,
      usage.extraUsageBalance,
      usage.extra,
      usage.overage,
      usage.managedComputers,
      usage.managedComputerUsage,
      usage.managedCompute,
      usage.compute,
      usage.computers,
      droidCoreConfig(usage),
    ))
  }

  function windowMetricWithDuration(metric, periodDurationMs) {
    if (!isObject(metric)) return null
    const out = {}
    const usedPercent = firstNumber(metric, [
      "usedPercent",
      "percentUsed",
      "usagePercent",
      "percentage",
      "percent",
    ])
    if (usedPercent !== null) out.usedPercent = usedPercent

    const windowEnd = firstValue(metric, ["windowEnd", "endDate", "endAt", "resetsAt", "resetAt"])
    if (windowEnd !== undefined && windowEnd !== null) out.endDate = windowEnd

    const secondsRemaining = firstNumber(metric, ["secondsRemaining", "remainingSeconds", "secondsLeft"])
    if (!("endDate" in out) && secondsRemaining !== null) {
      out.endDate = Date.now() + (secondsRemaining * 1000)
    }

    if (periodDurationMs > 0) out.periodDurationMs = periodDurationMs
    return Object.keys(out).length ? out : null
  }

  function mergeSupplementalUsage(ctx, accessToken, data, usage) {
    const merged = isObject(usage) ? Object.assign({}, usage) : {}
    const shouldFetchSupplemental = !hasExtendedUsageFields(merged) && (
      data.globalLimit !== undefined || data.userLimits !== undefined
    )
    if (!shouldFetchSupplemental) return merged

    const billing = requestGetJson(ctx, accessToken, BILLING_LIMITS_URL, "billing limits")
    if (isObject(billing)) {
      const limits = firstObject(billing.limits, billing.usageLimits)
      const standardLimits = limits && firstObject(limits.standard, limits.standardUsage)
      if (standardLimits && !firstObject(merged.standardUsage, merged.standardLimits, merged.usageLimits, merged.limits)) {
        const fiveHour = windowMetricWithDuration(firstObject(
          standardLimits.fiveHour,
          standardLimits.fiveHourUsage,
          standardLimits.five_hour,
          standardLimits["5Hour"],
          standardLimits["5-hour"],
        ), 5 * 60 * 60 * 1000)
        const weekly = windowMetricWithDuration(firstObject(
          standardLimits.weekly,
          standardLimits.weeklyUsage,
          standardLimits.week,
        ), 7 * 24 * 60 * 60 * 1000)
        const monthly = windowMetricWithDuration(firstObject(
          standardLimits.monthly,
          standardLimits.monthlyUsage,
          standardLimits.month,
        ), 30 * 24 * 60 * 60 * 1000)
        merged.standardUsage = {}
        if (fiveHour) merged.standardUsage.fiveHour = fiveHour
        if (weekly) merged.standardUsage.weekly = weekly
        if (monthly) merged.standardUsage.monthly = monthly
      }

      const extraUsageBalanceCents = firstNumber(billing, ["extraUsageBalanceCents", "extra_usage_balance_cents"])
      if (
        extraUsageBalanceCents !== null &&
        !firstObject(merged.extraUsage, merged.extra_usage, merged.extraUsageBalance, merged.extra, merged.overage)
      ) {
        merged.extraUsage = { remainingCents: extraUsageBalanceCents }
      }

      const coreLimits = limits && firstObject(limits.core, limits.droidCore, limits.droid_core)
      if (coreLimits && !droidCoreConfig(merged)) {
        merged.droidCore = { enabled: true }
      }
    }

    const compute = requestGetJson(ctx, accessToken, COMPUTE_USAGE_URL, "compute usage")
    if (isObject(compute) && !firstObject(
      merged.managedComputers,
      merged.managedComputerUsage,
      merged.computers,
      merged.compute,
      merged.managedCompute,
    )) {
      const limitMs = firstNumber(compute, ["limitMs", "includedMs", "allowanceMs", "totalMs", "limit"])
      if (limitMs !== null && limitMs > 0) {
        const usedMs = firstNumber(compute, ["orgUsageMs", "usageMs", "usedMs", "used"]) || 0
        merged.managedComputers = {
          usedHours: usedMs / (60 * 60 * 1000),
          includedHours: limitMs / (60 * 60 * 1000),
          startDate: firstValue(compute, ["periodStart", "startDate", "startAt"]),
          endDate: firstValue(compute, ["periodEnd", "endDate", "endAt"]),
        }
      }
    }

    return merged
  }

  function normalizePercent(value, ratioHint) {
    const n = asNumber(value)
    if (n === null) return null
    if (ratioHint || (n > 0 && n < 1)) return n * 100
    return n
  }

  function percentFromMetric(metric) {
    if (!isObject(metric)) return null
    const ratioValue = firstValue(metric, ["usedRatio", "usageRatio", "ratio"])
    if (ratioValue !== undefined) return normalizePercent(ratioValue, true)
    const percentValue = firstValue(metric, [
      "usedPercent",
      "percentUsed",
      "usagePercent",
      "percentage",
      "percent",
    ])
    if (percentValue !== undefined) return normalizePercent(percentValue, false)
    const used = firstNumber(metric, ["used", "value", "current", "usedAmount"])
    const limit = firstNumber(metric, ["limit", "allowance", "total", "totalAllowance"])
    if (used !== null && limit !== null && limit > 0) return (used / limit) * 100
    return null
  }

  function metricEndValue(metric, fallbackEnd) {
    const value = firstValue(metric, ["resetsAt", "resetAt", "endDate", "endAt", "periodEnd", "periodEndDate"])
    return value === undefined ? fallbackEnd : value
  }

  function metricStartValue(metric, fallbackStart) {
    const value = firstValue(metric, ["startDate", "startAt", "periodStart", "periodStartDate"])
    return value === undefined ? fallbackStart : value
  }

  function metricResetsAt(ctx, metric, fallbackEnd) {
    const value = metricEndValue(metric, fallbackEnd)
    return value === undefined || value === null ? null : ctx.util.toIso(value)
  }

  function metricPeriodDurationMs(metric, fallbackStart, fallbackEnd) {
    const explicit = firstNumber(metric, ["periodDurationMs", "durationMs", "periodMs"])
    if (explicit !== null && explicit > 0) return explicit
    const start = asNumber(metricStartValue(metric, fallbackStart))
    const end = asNumber(metricEndValue(metric, fallbackEnd))
    if (start !== null && end !== null && end > start) return end - start
    return null
  }

  function addPercentUsageLine(ctx, lines, label, metric, fallbackStart, fallbackEnd) {
    const used = percentFromMetric(metric)
    if (used === null) return false
    lines.push(ctx.line.progress({
      label,
      used: Math.round(used * 100) / 100,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: metricResetsAt(ctx, metric, fallbackEnd),
      periodDurationMs: metricPeriodDurationMs(metric, fallbackStart, fallbackEnd),
    }))
    return true
  }

  function addExtraUsageLine(ctx, lines, usage) {
    const extraUsage = firstObject(
      usage.extraUsage,
      usage.extra_usage,
      usage.extraUsageBalance,
      usage.extra,
      usage.overage,
    )
    if (!extraUsage) return false
    let remaining = firstNumber(extraUsage, [
      "remainingUsd",
      "remainingUSD",
      "remainingDollars",
      "balanceUsd",
      "balanceUSD",
      "balance",
      "amountRemainingUsd",
    ])
    const remainingCents = firstNumber(extraUsage, ["remainingCents", "balanceCents", "amountRemainingCents"])
    if (remaining === null && remainingCents !== null) remaining = remainingCents / 100
    if (remaining === null) return false
    lines.push(ctx.line.text({
      label: "Extra Usage",
      value: "$" + remaining.toFixed(2) + " remaining",
    }))
    return true
  }

  function isDroidCoreEnabled(usage) {
    const droidCore = droidCoreConfig(usage)
    return Boolean(droidCore && (
      droidCore.enabled === true ||
      droidCore.available === true ||
      droidCore.included === true
    ))
  }

  function addDroidCoreLine(ctx, lines, usage) {
    if (!isDroidCoreEnabled(usage)) return false
    lines.push(ctx.line.badge({
      label: "Droid Core",
      text: "Enabled",
      color: "#f97316",
    }))
    return true
  }

  function addManagedComputersLine(ctx, lines, usage, fallbackStart, fallbackEnd) {
    const managed = firstObject(
      usage.managedComputers,
      usage.managedComputerUsage,
      usage.computers,
      usage.compute,
      usage.managedCompute,
    )
    if (!managed) return false
    const managedUsed = firstNumber(managed, ["usedHours", "usageHours", "hoursUsed", "used", "current"])
    const used = managedUsed === null ? 0 : managedUsed
    const limit = firstNumber(managed, ["includedHours", "limitHours", "allowanceHours", "totalHours", "limit"])
    if (limit === null || limit <= 0) return false
    lines.push(ctx.line.progress({
      label: "Managed Computers",
      used,
      limit,
      format: { kind: "count", suffix: "h" },
      resetsAt: metricResetsAt(ctx, managed, fallbackEnd),
      periodDurationMs: metricPeriodDurationMs(managed, fallbackStart, fallbackEnd),
    }))
    return true
  }

  function inferPlan(ctx, usage, standard) {
    const rawPlan = firstValue(usage, ["plan", "planName", "tier", "usageMode", "currentUsageMode"])
    let plan = typeof rawPlan === "string" && rawPlan.trim()
      ? ctx.fmt.planLabel(rawPlan.trim())
      : null
    if (!plan && standard && typeof standard.totalAllowance === "number") {
      const allowance = standard.totalAllowance
      if (allowance >= 200000000) {
        plan = "Max"
      } else if (allowance >= 20000000) {
        plan = "Pro"
      } else if (allowance > 0) {
        plan = "Basic"
      }
    }
    if (isDroidCoreEnabled(usage)) return plan ? plan + " + Droid Core" : "Droid Core"
    return plan
  }

  function probe(ctx) {
    const authState = loadAuth(ctx)
    if (!authState) {
      ctx.host.log.error("probe failed: not logged in")
      throw "Not logged in. Run `droid` to authenticate."
    }

    const auth = authState.auth
    if (!auth.access_token) {
      ctx.host.log.error("probe failed: no access_token in auth data")
      throw "Invalid auth file. Run `droid` to authenticate."
    }

    let accessToken = auth.access_token

    // Check if token needs refresh
    const nowMs = Date.now()
    if (needsRefresh(ctx, accessToken, nowMs)) {
      ctx.host.log.info("token near expiry, refreshing")
      try {
        const refreshed = refreshToken(ctx, authState)
        if (refreshed) {
          accessToken = refreshed
        } else {
          ctx.host.log.warn("proactive refresh failed, trying with existing token")
        }
      } catch (e) {
        if (!canUseExistingAccessToken(ctx, accessToken, nowMs)) throw e
        ctx.host.log.warn("proactive refresh failed but access token is still valid, trying existing token")
      }
    }

    let resp
    let didRefresh = false
    try {
      resp = ctx.util.retryOnceOnAuth({
        request: (token) => {
          try {
            const effectiveToken = token || accessToken
            accessToken = effectiveToken
            return fetchUsage(ctx, effectiveToken)
          } catch (e) {
            ctx.host.log.error("usage request exception: " + String(e))
            if (didRefresh) {
              throw "Usage request failed after refresh. Try again."
            }
            throw "Usage request failed. Check your connection."
          }
        },
        refresh: () => {
          ctx.host.log.info("usage returned 401, attempting refresh")
          didRefresh = true
          return refreshToken(ctx, authState)
        },
      })
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("usage request failed: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      ctx.host.log.error("usage returned auth error after all retries: status=" + resp.status)
      throw "Token expired. Run `droid` to log in again."
    }

    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.error("usage returned error: status=" + resp.status)
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    ctx.host.log.info("usage fetch succeeded")

    const data = ctx.util.tryParseJson(resp.bodyText)
    if (data === null) {
      throw "Usage response invalid. Try again later."
    }

    let usage = data.usage
    if (!usage) {
      throw "Usage response missing data. Try again later."
    }
    usage = mergeSupplementalUsage(ctx, accessToken, data, usage)

    const lines = []

    // Calculate reset time and period from usage dates
    const endDate = usage.endDate
    const startDate = usage.startDate
    const resetsAt = typeof endDate === "number" ? ctx.util.toIso(endDate) : null
    const periodDurationMs = (typeof endDate === "number" && typeof startDate === "number")
      ? (endDate - startDate)
      : null

    addExtraUsageLine(ctx, lines, usage)

    const standardUsage = firstObject(
      usage.standardUsage,
      usage.standardLimits,
      usage.usageLimits,
      usage.limits,
    )
    if (standardUsage) {
      addPercentUsageLine(ctx, lines, "5-hour usage", firstObject(
        standardUsage.fiveHour,
        standardUsage.fiveHourUsage,
        standardUsage.five_hour,
        standardUsage["5Hour"],
        standardUsage["5-hour"],
      ), startDate, endDate)
      addPercentUsageLine(ctx, lines, "Weekly usage", firstObject(
        standardUsage.weekly,
        standardUsage.weeklyUsage,
        standardUsage.week,
      ), startDate, endDate)
      addPercentUsageLine(ctx, lines, "Monthly usage", firstObject(
        standardUsage.monthly,
        standardUsage.monthlyUsage,
        standardUsage.month,
      ), startDate, endDate)
    }

    addDroidCoreLine(ctx, lines, usage)
    addManagedComputersLine(ctx, lines, usage, startDate, endDate)

    // Standard tokens (primary line)
    const standard = usage.standard
    if (standard && typeof standard.totalAllowance === "number") {
      const used = standard.orgTotalTokensUsed || 0
      const limit = standard.totalAllowance
      lines.push(ctx.line.progress({
        label: "Standard",
        used: used,
        limit: limit,
        format: { kind: "count", suffix: "tokens" },
        resetsAt: resetsAt,
        periodDurationMs: periodDurationMs,
      }))
    }

    // Premium tokens (detail line, only if plan includes premium)
    const premium = usage.premium
    if (premium && typeof premium.totalAllowance === "number" && premium.totalAllowance > 0) {
      const used = premium.orgTotalTokensUsed || 0
      const limit = premium.totalAllowance
      lines.push(ctx.line.progress({
        label: "Premium",
        used: used,
        limit: limit,
        format: { kind: "count", suffix: "tokens" },
        resetsAt: resetsAt,
        periodDurationMs: periodDurationMs,
      }))
    }

    const plan = inferPlan(ctx, usage, standard)

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "factory", probe }
})()
