(function () {
  const LOCAL_USER_ENDPOINT = "https://www.perplexity.ai/api/user"
  const REST_API_BASE = "https://www.perplexity.ai/rest/pplx-api/v2"
  const REST_GROUPS_ENDPOINT = REST_API_BASE + "/groups"

  const LOCAL_CACHE_DB_PATHS = [
    "~/Library/Containers/ai.perplexity.mac/Data/Library/Caches/ai.perplexity.mac/Cache.db",
    "~/Library/Caches/ai.perplexity.mac/Cache.db",
  ]

  // Only need request_object; receiver body is optional and can be malformed.
  const LOCAL_SESSION_SQL =
    "SELECT hex(b.request_object) AS requestHex " +
    "FROM cfurl_cache_response r " +
    "JOIN cfurl_cache_blob_data b ON b.entry_ID = r.entry_ID " +
    "WHERE r.request_key = '" + LOCAL_USER_ENDPOINT + "' " +
    "ORDER BY r.entry_ID DESC LIMIT 1;"

  const BEARER_HEX_PREFIX = "42656172657220" // "Bearer "
  const ASK_UA_HEX_PREFIX = "41736B2F" // Ask/
  const MACOS_DEVICE_ID_HEX_PREFIX = "6D61636F733A" // macos:
  const MAX_REQUEST_FIELD_LENGTH = 220

  function readNumberField(obj, keys) {
    if (!obj || typeof obj !== "object") return null
    for (let i = 0; i < keys.length; i += 1) {
      const n = Number(obj[keys[i]])
      if (Number.isFinite(n)) return n
    }
    return null
  }

  function parseMoneyNumber(value) {
    if (value === null || value === undefined) return null
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value !== "string") return null
    const trimmed = value.trim()
    if (!trimmed) return null
    const cleaned = trimmed.replace(/[$,]/g, "")
    const n = Number(cleaned)
    return Number.isFinite(n) ? n : null
  }

  function readMoneyLike(value) {
    const direct = parseMoneyNumber(value)
    if (direct !== null) return direct
    if (!value || typeof value !== "object") return null

    const cents = readNumberField(value, ["cents", "amount_cents", "amountCents", "value_cents", "valueCents"])
    if (cents !== null) {
      const dollars = cents / 100
      return Number.isFinite(dollars) ? dollars : null
    }

    return (
      readNumberField(value, ["usd", "amount_usd", "amountUsd", "value_usd", "valueUsd"]) ??
      readNumberField(value, ["amount", "value", "balance", "remaining", "available"])
    )
  }

  function isAllowedAuthByte(byte) {
    return (
      (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x5a) ||
      (byte >= 0x61 && byte <= 0x7a) ||
      byte === 0x2e ||
      byte === 0x2d ||
      byte === 0x5f
    )
  }

  function extractAuthToken(requestHex) {
    if (typeof requestHex !== "string") return null
    const upper = requestHex.trim().toUpperCase()
    if (!upper) return null
    const idx = upper.indexOf(BEARER_HEX_PREFIX)
    if (idx === -1) return null
    const start = idx + BEARER_HEX_PREFIX.length
    let token = ""
    for (let i = start; i + 1 < upper.length; i += 2) {
      const byte = parseInt(upper.slice(i, i + 2), 16)
      if (!Number.isFinite(byte)) break
      if (!isAllowedAuthByte(byte)) break
      if (byte === 0x5f) {
        // Stop before bplist marker bytes; avoids capturing '_' that precedes plist int markers.
        const next = i + 3 < upper.length ? parseInt(upper.slice(i + 2, i + 4), 16) : NaN
        if (next === 0x10 || next === 0x11 || next === 0x12 || next === 0x13 || next === 0x14) break
      }
      token += String.fromCharCode(byte)
    }
    const dots = (token.match(/\./g) || []).length
    return dots >= 2 ? token : null
  }

  function isPrintableAscii(byte) {
    return byte >= 0x20 && byte <= 0x7e
  }

  function extractPrintableField(requestHex, prefixHex) {
    if (typeof requestHex !== "string") return null
    const upper = requestHex.trim().toUpperCase()
    if (!upper) return null
    const idx = upper.indexOf(prefixHex)
    if (idx === -1) return null
    let out = ""
    for (let i = idx; i + 1 < upper.length && out.length < MAX_REQUEST_FIELD_LENGTH; i += 2) {
      const byte = parseInt(upper.slice(i, i + 2), 16)
      if (!Number.isFinite(byte) || !isPrintableAscii(byte)) break
      out += String.fromCharCode(byte)
    }
    return out ? out : null
  }

  function askAppVersionFromUserAgent(userAgent) {
    if (typeof userAgent !== "string") return null
    const m = /^Ask\/([^/]+)/.exec(userAgent.trim())
    return m && m[1] ? m[1] : null
  }

  function makeRestHeaderOverrides(session) {
    const headers = {
      Accept: "*/*",
      "User-Agent": (session && session.userAgent) || "Ask/0 (macOS) isiOSOnMac/false",
      "X-Client-Name": "Perplexity-Mac",
      "X-App-ApiVersion": "2.17",
      "X-App-ApiClient": "macos",
      "X-Client-Env": "production",
    }
    if (session && session.appVersion) headers["X-App-Version"] = session.appVersion
    if (session && session.deviceId) headers["X-Device-ID"] = session.deviceId
    return headers
  }

  function fetchJsonOptional(ctx, url, authToken, extraHeaders) {
    if (!authToken) return null
    let resp
    try {
      const headers = {
        Authorization: "Bearer " + authToken,
        Accept: "application/json",
        "User-Agent": "OpenUsage",
      }
      if (extraHeaders && typeof extraHeaders === "object") for (const k in extraHeaders) headers[k] = extraHeaders[k]
      resp = ctx.util.request({ method: "GET", url: url, headers: headers, timeoutMs: 10000 })
    } catch (e) {
      ctx.host.log.warn("request failed (" + url + "): " + String(e))
      return null
    }
    if (ctx.util.isAuthStatus(resp.status)) {
      if (resp.status === 403 && typeof resp.bodyText === "string" && resp.bodyText.indexOf("Just a moment") !== -1) {
        ctx.host.log.warn("cloudflare challenge (try opening perplexity.ai in a browser once)")
      }
      ctx.host.log.warn("request unauthorized (" + url + "): status=" + String(resp.status))
      return null
    }
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("request returned status " + String(resp.status) + " (" + url + ")")
      return null
    }
    const parsed = ctx.util.tryParseJson(resp.bodyText)
    if (!parsed || typeof parsed !== "object") {
      ctx.host.log.warn("request returned invalid JSON (" + url + ")")
      return null
    }
    return parsed
  }

  function readGroupId(value) {
    if (value === null || value === undefined) return null
    if (typeof value === "string") {
      const trimmed = value.trim()
      return trimmed ? trimmed : null
    }
    const n = Number(value)
    if (Number.isFinite(n)) return String(Math.floor(n))
    return null
  }

  function pickGroupId(groupsJson) {
    const tryFromObj = (obj) => {
      if (!obj || typeof obj !== "object") return null
      return (
        readGroupId(obj.api_org_id) ||
        readGroupId(obj.apiOrgId) ||
        readGroupId(obj.org_id) ||
        readGroupId(obj.orgId) ||
        readGroupId(obj.id) ||
        readGroupId(obj.group_id) ||
        readGroupId(obj.groupId)
      )
    }

    const tryFromArray = (arr) => {
      if (!Array.isArray(arr)) return null
      let first = null
      for (let i = 0; i < arr.length; i += 1) {
        const item = arr[i]
        const id = tryFromObj(item)
        if (!id) continue
        if (!first) first = id
        if (item && (item.is_default_org === true || item.isDefaultOrg === true)) return id
      }
      return first
    }

    if (Array.isArray(groupsJson)) return tryFromArray(groupsJson)
    if (!groupsJson || typeof groupsJson !== "object") return null

    const direct = tryFromObj(groupsJson)
    if (direct) return direct

    const keys = ["orgs", "groups", "results", "items", "data"]
    for (let i = 0; i < keys.length; i += 1) {
      const id = tryFromArray(groupsJson[keys[i]])
      if (id) return id
    }
    return null
  }

  function readBalanceUsd(group) {
    const wrappers = ["apiOrganization", "api_organization", "group", "org", "organization", "data", "result", "item"]
    const keys = ["balance_usd", "balanceUsd", "balance", "pending_balance", "pendingBalance"]

    const tryNode = (node) => {
      if (!node) return null
      if (Array.isArray(node)) {
        for (let i = 0; i < node.length; i += 1) {
          const n = tryNode(node[i])
          if (n !== null) return n
        }
        return null
      }
      if (typeof node !== "object") return null

      for (let i = 0; i < wrappers.length; i += 1) {
        const n = tryNode(node[wrappers[i]])
        if (n !== null) return n
      }

      let n = readNumberField(node, keys)
      if (n !== null) return n

      for (let i = 0; i < keys.length; i += 1) {
        n = readMoneyLike(node[keys[i]])
        if (n !== null) return n
      }

      const nested = [node.customerInfo, node.wallet, node.billing, node.usage, node.account, node.balances]
      for (let i = 0; i < nested.length; i += 1) {
        n = tryNode(nested[i])
        if (n !== null) return n
      }

      for (const k in node) if (/(balance|credit|wallet|prepaid|available)/i.test(k)) {
        n = readMoneyLike(node[k])
        if (n !== null) return n
      }
      return null
    }

    return tryNode(group)
  }

  function sumUsageCostUsd(usageAnalytics) {
    if (!Array.isArray(usageAnalytics)) return null
    let costSum = 0
    let hasCost = false
    for (let i = 0; i < usageAnalytics.length; i += 1) {
      const meter = usageAnalytics[i]
      if (!meter || typeof meter !== "object") continue
      const summaries = meter.meter_event_summaries || meter.meterEventSummaries
      if (!Array.isArray(summaries)) continue
      for (let j = 0; j < summaries.length; j += 1) {
        const s = summaries[j]
        if (!s || typeof s !== "object") continue
        const c = Number(s.cost)
        if (Number.isFinite(c)) {
          costSum += c
          hasCost = true
        }
      }
    }
    return hasCost ? costSum : null
  }

  function queryLocalSessionFromCache(ctx, dbPath) {
    let rows
    try {
      const json = ctx.host.sqlite.query(dbPath, LOCAL_SESSION_SQL)
      rows = ctx.util.tryParseJson(json)
    } catch (e) {
      ctx.host.log.warn("local sqlite read failed (" + dbPath + "): " + String(e))
      return null
    }
    if (!Array.isArray(rows) || rows.length === 0) return null

    const row = rows[0] || {}
    const requestHex = typeof row.requestHex === "string" ? row.requestHex : null
    if (!requestHex) return null

    const authToken = extractAuthToken(requestHex)
    if (!authToken) return null

    const userAgent = extractPrintableField(requestHex, ASK_UA_HEX_PREFIX)
    const appVersion = askAppVersionFromUserAgent(userAgent)
    const deviceId = extractPrintableField(requestHex, MACOS_DEVICE_ID_HEX_PREFIX)

    return { authToken: authToken, userAgent: userAgent, appVersion: appVersion, deviceId: deviceId, sourcePath: dbPath }
  }

  function loadLocalSession(ctx) {
    for (let i = 0; i < LOCAL_CACHE_DB_PATHS.length; i += 1) {
      const dbPath = LOCAL_CACHE_DB_PATHS[i]
      try {
        if (!ctx.host.fs.exists(dbPath)) continue
      } catch (e) {
        ctx.host.log.warn("local cache exists check failed (" + dbPath + "): " + String(e))
        continue
      }
      const found = queryLocalSessionFromCache(ctx, dbPath)
      if (found) return found
    }
    return null
  }

  function fetchRestState(ctx, session) {
    const authToken = session && session.authToken
    if (!authToken) return null
    const restHeaders = makeRestHeaderOverrides(session)
    const groups =
      fetchJsonOptional(ctx, REST_GROUPS_ENDPOINT, authToken, restHeaders) ||
      fetchJsonOptional(ctx, REST_GROUPS_ENDPOINT + "/", authToken, restHeaders)
    const groupId = pickGroupId(groups)
    if (!groupId) return null
    const base = REST_API_BASE + "/groups/" + encodeURIComponent(groupId)
    const group =
      fetchJsonOptional(ctx, base, authToken, restHeaders) ||
      fetchJsonOptional(ctx, base + "/", authToken, restHeaders)
    const usageUrl = base + "/usage-analytics"
    const usageAnalytics =
      fetchJsonOptional(ctx, usageUrl, authToken, restHeaders) ||
      fetchJsonOptional(ctx, usageUrl + "/", authToken, restHeaders)
    return { groupId: groupId, group: group, usageAnalytics: usageAnalytics }
  }

  function probe(ctx) {
    const session = loadLocalSession(ctx)
    if (!session) throw "Not logged in. Sign in via Perplexity app."
    if (session.sourcePath) ctx.host.log.info("using cache db: " + session.sourcePath)

    const restState = fetchRestState(ctx, session)
    if (!restState || !restState.group) throw "Balance unavailable. Try again later."

    const balanceUsd = readBalanceUsd(restState.group)
    if (balanceUsd === null) throw "Balance unavailable. Try again later."

    const usedUsd = sumUsageCostUsd(restState.usageAnalytics)
    if (usedUsd === null) throw "Usage unavailable. Try again later."
    const usedCents = Math.max(0, Math.round(usedUsd * 100))
    const limitCents = Math.max(0, Math.round(balanceUsd * 100))
    if (!Number.isFinite(limitCents) || limitCents <= 0) throw "Balance unavailable. Try again later."

    const line = ctx.line.progress({
      label: "Usage",
      used: usedCents / 100,
      limit: limitCents / 100,
      format: { kind: "dollars" },
    })

    let plan = null
    const isPro = restState.group && restState.group.customerInfo && restState.group.customerInfo.is_pro
    if (isPro === true) plan = "Pro"

    return plan ? { plan: plan, lines: [line] } : { lines: [line] }
  }

  globalThis.__openusage_plugin = { id: "perplexity", probe: probe }
})()
