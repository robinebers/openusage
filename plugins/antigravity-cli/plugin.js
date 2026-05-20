(function () {
  const PROVIDER_ID = "antigravity-cli"
  const CLI_STATE_DIR = "~/.gemini/antigravity-cli"
  const KEYCHAIN_SERVICE = "gemini"
  const KEYCHAIN_ACCOUNT = "antigravity"
  const LOGIN_MESSAGE = "Not logged in. Run `agy` and complete Google sign-in first."

  const LOAD_CODE_ASSIST_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
  const FETCH_MODELS_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
  const RETRIEVE_QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
  const QUOTA_PERIOD_MS = 5 * 60 * 60 * 1000

  const IDE_METADATA = {
    ideType: "IDE_UNSPECIFIED",
    platform: "PLATFORM_UNSPECIFIED",
    pluginType: "GEMINI",
    duetProject: "default",
  }

  function trimString(value) {
    return typeof value === "string" ? value.trim() : ""
  }

  function decodeBase64(ctx, text) {
    try {
      return ctx.base64.decode(text)
    } catch (e) {
      return null
    }
  }

  function readKeychainValue(ctx) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readGenericPassword !== "function") {
      return null
    }

    try {
      var accountValue = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)
      if (accountValue) return accountValue
    } catch (e) {
      ctx.host.log.info("antigravity-cli account keychain read failed: " + String(e))
    }

    try {
      return ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE)
    } catch (e) {
      ctx.host.log.info("antigravity-cli service keychain read failed: " + String(e))
      return null
    }
  }

  function unwrapKeychainText(ctx, raw) {
    var text = trimString(raw)
    if (!text) return null
    if (text.indexOf("go-keyring-base64:") === 0) {
      var decoded = decodeBase64(ctx, text.slice("go-keyring-base64:".length))
      text = trimString(decoded)
    }
    return text || null
  }

  function extractTokenFromObject(obj) {
    if (!obj || typeof obj !== "object") return null

    var directKeys = [
      "access_token",
      "accessToken",
      "token",
      "id_token",
      "idToken",
      "bearerToken",
      "auth_token",
      "authToken",
    ]
    for (var i = 0; i < directKeys.length; i += 1) {
      var value = obj[directKeys[i]]
      if (typeof value === "string" && value.trim()) return value.trim()
    }

    var nestedKeys = ["tokens", "oauth", "oauth2", "credentials", "auth"]
    for (var j = 0; j < nestedKeys.length; j += 1) {
      var nested = extractTokenFromObject(obj[nestedKeys[j]])
      if (nested) return nested
    }

    return null
  }

  function extractAccessToken(ctx, raw) {
    var text = unwrapKeychainText(ctx, raw)
    if (!text) return null

    var parsed = ctx.util.tryParseJson(text)
    if (typeof parsed === "string" && parsed.trim()) return parsed.trim()
    if (parsed) {
      var token = extractTokenFromObject(parsed)
      if (token) return token
    }

    if (text.indexOf("Bearer ") === 0) return text.slice("Bearer ".length).trim() || null
    return text
  }

  function readNonSecretCliContext(ctx) {
    var context = {}
    try {
      if (ctx.host.fs.exists(CLI_STATE_DIR)) {
        context.hasStateDir = true
      }
    } catch (e) {
      context.hasStateDir = false
    }
    return context
  }

  function requestJson(ctx, url, token, body) {
    var request = ctx.host.http && typeof ctx.host.http.request === "function"
      ? ctx.host.http.request
      : ctx.util.request
    var resp = request({
      method: "POST",
      url: url,
      headers: {
        Authorization: "Bearer " + token,
        Accept: "application/json",
        "Content-Type": "application/json",
        "User-Agent": "agy",
      },
      bodyText: JSON.stringify(body || {}),
      timeoutMs: 15000,
    })
    if (ctx.util.isAuthStatus(resp.status)) {
      throw LOGIN_MESSAGE
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw "Antigravity CLI quota request failed (HTTP " + String(resp.status) + "). Try again later."
    }
    var data = ctx.util.tryParseJson(resp.bodyText)
    return data && typeof data === "object" ? data : null
  }

  function readFirstStringDeep(value, keys) {
    if (!value || typeof value !== "object") return null
    for (var i = 0; i < keys.length; i += 1) {
      var v = value[keys[i]]
      if (typeof v === "string" && v.trim()) return v.trim()
    }
    var values = Object.values(value)
    for (var j = 0; j < values.length; j += 1) {
      var found = readFirstStringDeep(values[j], keys)
      if (found) return found
    }
    return null
  }

  function readPlan(loadCodeAssistData) {
    var direct = loadCodeAssistData && loadCodeAssistData.userTier
    if (direct && typeof direct.name === "string" && direct.name.trim()) return direct.name.trim()
    var equivalent = readTierObjectName(loadCodeAssistData)
    if (equivalent) return equivalent
    return readFirstStringDeep(loadCodeAssistData, ["userTierName", "tierName", "planName"])
  }

  function readTierObjectName(value) {
    if (!value || typeof value !== "object") return null
    var tierKeys = ["userTier", "tier", "subscriptionTier", "plan"]
    for (var i = 0; i < tierKeys.length; i += 1) {
      var tier = value[tierKeys[i]]
      if (tier && typeof tier === "object" && typeof tier.name === "string" && tier.name.trim()) {
        return tier.name.trim()
      }
    }
    var values = Object.values(value)
    for (var j = 0; j < values.length; j += 1) {
      var found = readTierObjectName(values[j])
      if (found) return found
    }
    return null
  }

  function modelText(value) {
    var parts = []
    if (!value || typeof value !== "object") return ""
    var keys = ["label", "displayName", "name", "model", "modelId", "model_id", "id"]
    for (var i = 0; i < keys.length; i += 1) {
      if (typeof value[keys[i]] === "string") parts.push(value[keys[i]])
    }
    return parts.join(" ").toLowerCase()
  }

  function poolForText(text) {
    var lower = String(text || "").toLowerCase()
    if (lower.indexOf("gemini") !== -1 && lower.indexOf("pro") !== -1) return "Gemini Pro"
    if (lower.indexOf("gemini") !== -1 && lower.indexOf("flash") !== -1) return "Gemini Flash"
    if (lower.indexOf("gemini") !== -1) return null
    if (lower) return "Claude"
    return null
  }

  function pushBucket(out, pool, remainingFraction, resetTime) {
    if (!pool || !Number.isFinite(remainingFraction)) return
    out.push({
      pool: pool,
      remainingFraction: remainingFraction,
      resetTime: resetTime || null,
    })
  }

  function collectFetchModelBuckets(value, out) {
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i += 1) collectFetchModelBuckets(value[i], out)
      return
    }
    if (!value || typeof value !== "object") return
    if (value.isInternal) return

    var quota = value.quotaInfo || value.quota || null
    var remaining = quota && typeof quota.remainingFraction === "number"
      ? quota.remainingFraction
      : typeof value.remainingFraction === "number"
        ? value.remainingFraction
        : null
    if (remaining !== null) {
      var text = modelText(value)
      if (text) {
        pushBucket(out, poolForText(text), remaining, (quota && (quota.resetTime || quota.reset_time)) || value.resetTime || value.reset_time)
      }
    }

    var children = Object.values(value)
    for (var j = 0; j < children.length; j += 1) collectFetchModelBuckets(children[j], out)
  }

  function collectQuotaBuckets(value, out, inheritedText) {
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i += 1) collectQuotaBuckets(value[i], out, inheritedText)
      return
    }
    if (!value || typeof value !== "object") return

    var text = (inheritedText || "") + " " + modelText(value)
    if (typeof value.remainingFraction === "number") {
      pushBucket(out, poolForText(text), value.remainingFraction, value.resetTime || value.reset_time)
    }

    var entries = Object.keys(value)
    for (var j = 0; j < entries.length; j += 1) {
      var key = entries[j]
      collectQuotaBuckets(value[key], out, text + " " + key)
    }
  }

  function dedupeBuckets(buckets) {
    var byPool = {}
    for (var i = 0; i < buckets.length; i += 1) {
      var bucket = buckets[i]
      if (!byPool[bucket.pool] || bucket.remainingFraction < byPool[bucket.pool].remainingFraction) {
        byPool[bucket.pool] = bucket
      }
    }
    return byPool
  }

  function lineForBucket(ctx, label, bucket) {
    var clamped = Math.max(0, Math.min(1, Number(bucket.remainingFraction)))
    var opts = {
      label: label,
      used: Math.round((1 - clamped) * 100),
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: QUOTA_PERIOD_MS,
    }
    if (bucket.resetTime) {
      var iso = ctx.util.toIso ? ctx.util.toIso(bucket.resetTime) : bucket.resetTime
      if (iso) opts.resetsAt = iso
    }
    return ctx.line.progress(opts)
  }

  function buildLines(ctx, buckets) {
    var byPool = dedupeBuckets(buckets)
    var order = ["Gemini Pro", "Gemini Flash", "Claude"]
    var lines = []
    for (var i = 0; i < order.length; i += 1) {
      var label = order[i]
      if (byPool[label]) lines.push(lineForBucket(ctx, label, byPool[label]))
    }
    return lines
  }

  function probe(ctx) {
    readNonSecretCliContext(ctx)

    var token = extractAccessToken(ctx, readKeychainValue(ctx))
    if (!token) throw LOGIN_MESSAGE

    var loadData = requestJson(ctx, LOAD_CODE_ASSIST_URL, token, { metadata: IDE_METADATA })
    var plan = readPlan(loadData)

    var fetchData = requestJson(ctx, FETCH_MODELS_URL, token, { metadata: IDE_METADATA })
    var buckets = []
    collectFetchModelBuckets(fetchData, buckets)

    if (buckets.length === 0) {
      var quotaData = requestJson(ctx, RETRIEVE_QUOTA_URL, token, { metadata: IDE_METADATA })
      collectQuotaBuckets(quotaData, buckets, "")
    }

    var lines = buildLines(ctx, buckets)
    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No quota data", color: "#a3a3a3" }))
    }

    return { plan: plan || undefined, lines: lines }
  }

  globalThis.__openusage_plugin = { id: PROVIDER_ID, probe: probe }
})()
