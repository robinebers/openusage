(function () {
  const SETTINGS_URL = "https://ollama.com/settings"
  const ACCOUNT_USAGE_URL = "https://ollama.com/api/account/usage"
  const SESSION_COOKIE_NAME = "__Secure-session"
  const SESSION_MS = 5 * 60 * 60 * 1000
  const WEEK_MS = 7 * 24 * 60 * 60 * 1000
  const KEYCHAIN_SESSION_SERVICE = "OpenUsage Ollama Session"
  const KEYCHAIN_COOKIE_SERVICE = "OpenUsage Ollama Cookie"
  const FIREFOX_PROFILE_ROOTS = [
    "~/Library/Application Support/Firefox/Profiles",
    "~/Library/Application Support/LibreWolf/Profiles",
  ]

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

  function clampPercent(value) {
    const n = readNumber(value)
    if (n === null) return null
    if (n < 0) return 0
    if (n > 100) return 100
    return n
  }

  function getEnv(ctx, name) {
    try {
      return readString(ctx.host.env.get(name))
    } catch (e) {
      ctx.host.log.warn("env read failed for " + name + ": " + String(e))
      return null
    }
  }

  function loadApiKey(ctx) {
    return getEnv(ctx, "OLLAMA_API_KEY")
  }

  function extractSessionCookie(raw) {
    const text = readString(raw)
    if (!text) return null
    const header = text.replace(/^Cookie:\s*/i, "")
    const parts = header.split(";")
    for (let i = 0; i < parts.length; i += 1) {
      const part = parts[i].trim()
      const eq = part.indexOf("=")
      if (eq === -1) continue
      if (part.slice(0, eq).trim() === SESSION_COOKIE_NAME) {
        return readString(part.slice(eq + 1))
      }
    }
    return header.indexOf("=") === -1 ? header : null
  }

  function readKeychain(ctx, service) {
    try {
      return readString(ctx.host.keychain.readGenericPasswordForCurrentUser(service))
    } catch (e) {
      return null
    }
  }

  function readFirefoxCookie(ctx) {
    for (let r = 0; r < FIREFOX_PROFILE_ROOTS.length; r += 1) {
      const root = FIREFOX_PROFILE_ROOTS[r]
      let profiles = []
      try {
        if (!ctx.host.fs.exists(root)) continue
        profiles = ctx.host.fs.listDir(root)
      } catch (e) {
        continue
      }

      profiles = profiles.slice().sort(function (a, b) {
        const ar = /default-release|default/i.test(a) ? 0 : 1
        const br = /default-release|default/i.test(b) ? 0 : 1
        return ar - br || String(a).localeCompare(String(b))
      })

      for (let i = 0; i < profiles.length; i += 1) {
        const db = root + "/" + profiles[i] + "/cookies.sqlite"
        try {
          if (!ctx.host.fs.exists(db)) continue
          const rowsJson = ctx.host.sqlite.query(
            db,
            "SELECT value FROM moz_cookies " +
              "WHERE host IN ('.ollama.com', 'ollama.com') " +
              "AND name = '__Secure-session' " +
              "ORDER BY expiry DESC LIMIT 1;"
          )
          const rows = ctx.util.tryParseJson(rowsJson)
          if (Array.isArray(rows) && rows.length > 0) {
            const value = extractSessionCookie(rows[0] && rows[0].value)
            if (value) return { value: value, source: "Firefox" }
          }
        } catch (e) {
          ctx.host.log.warn("firefox cookie read failed: " + String(e))
        }
      }
    }
    return null
  }

  function loadSessionCookie(ctx) {
    const envSession = extractSessionCookie(getEnv(ctx, "OLLAMA_SESSION_COOKIE"))
    if (envSession) return { value: envSession, source: "OLLAMA_SESSION_COOKIE" }

    const envCookie = extractSessionCookie(getEnv(ctx, "OLLAMA_COOKIE"))
    if (envCookie) return { value: envCookie, source: "OLLAMA_COOKIE" }

    const keychainSession = extractSessionCookie(readKeychain(ctx, KEYCHAIN_SESSION_SERVICE))
    if (keychainSession) return { value: keychainSession, source: "keychain" }

    const keychainCookie = extractSessionCookie(readKeychain(ctx, KEYCHAIN_COOKIE_SERVICE))
    if (keychainCookie) return { value: keychainCookie, source: "keychain" }

    return readFirefoxCookie(ctx)
  }

  function requestJson(ctx, url, headers) {
    let resp
    try {
      resp = ctx.util.request({ method: "GET", url: url, headers: headers, timeoutMs: 10000 })
    } catch (e) {
      ctx.host.log.warn("request failed (" + url + "): " + String(e))
      return null
    }
    if (resp.status === 404) return null
    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Ollama API key invalid. Check OLLAMA_API_KEY."
    }
    if (resp.status < 200 || resp.status >= 300) return null
    const json = ctx.util.tryParseJson(resp.bodyText)
    return json && typeof json === "object" ? json : null
  }

  function findNestedObject(root, keys) {
    if (!root || typeof root !== "object") return null
    for (let i = 0; i < keys.length; i += 1) {
      const value = root[keys[i]]
      if (value && typeof value === "object") return value
    }
    return null
  }

  function parseApiUsage(data) {
    const body = data && typeof data.data === "object" ? data.data : data
    if (!body || typeof body !== "object") return null

    const session = findNestedObject(body, ["session", "session_usage", "sessionUsage"])
    const weekly = findNestedObject(body, ["weekly", "weekly_usage", "weeklyUsage"])
    const sessionPercent = clampPercent(
      session
        ? session.used_percent ?? session.usedPercent ?? session.percent ?? session.percentage
        : body.session_percent ?? body.sessionPercent
    )
    const weeklyPercent = clampPercent(
      weekly
        ? weekly.used_percent ?? weekly.usedPercent ?? weekly.percent ?? weekly.percentage
        : body.weekly_percent ?? body.weeklyPercent
    )
    if (sessionPercent === null || weeklyPercent === null) return null

    return {
      plan: readString(body.plan || body.tier || body.subscription),
      sessionPercent: sessionPercent,
      weeklyPercent: weeklyPercent,
      sessionResetsAt: session ? session.resets_at || session.resetsAt || null : body.session_resets_at || null,
      weeklyResetsAt: weekly ? weekly.resets_at || weekly.resetsAt || null : body.weekly_resets_at || null,
      source: "API",
    }
  }

  function decodeHtml(text) {
    return String(text || "")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&#(\d+);/g, function (_, n) {
        return String.fromCharCode(Number(n))
      })
      .replace(/&#x([0-9a-f]+);/gi, function (_, n) {
        return String.fromCharCode(parseInt(n, 16))
      })
  }

  function textFromHtml(html) {
    return decodeHtml(
      String(html || "")
        .replace(/<script[\s\S]*?<\/script>/gi, " ")
        .replace(/<style[\s\S]*?<\/style>/gi, " ")
        .replace(/<[^>]+>/g, " ")
    ).replace(/\s+/g, " ").trim()
  }

  function addDuration(nowMs, amount, unit) {
    const n = Number(amount)
    if (!Number.isFinite(n) || n < 0) return null
    const u = String(unit || "").toLowerCase()
    let factor = 1000
    if (u.indexOf("minute") === 0 || u === "min" || u === "m") factor = 60 * 1000
    else if (u.indexOf("hour") === 0 || u === "h") factor = 60 * 60 * 1000
    else if (u.indexOf("day") === 0 || u === "d") factor = 24 * 60 * 60 * 1000
    else if (u.indexOf("week") === 0 || u === "w") factor = 7 * 24 * 60 * 60 * 1000
    return new Date(nowMs + n * factor).toISOString()
  }

  function relativeResetIso(section, nowIso) {
    const nowMs = Date.parse(nowIso)
    if (!Number.isFinite(nowMs)) return null
    const m = /Resets in\s+(?:less than\s+)?(\d+(?:\.\d+)?)\s*(second|seconds|minute|minutes|min|m|hour|hours|h|day|days|d|week|weeks|w)/i.exec(section)
    return m ? addDuration(nowMs, m[1], m[2]) : null
  }

  function sectionBetween(text, startLabel, endLabel) {
    const start = text.toLowerCase().indexOf(startLabel.toLowerCase())
    if (start === -1) return ""
    const after = text.slice(start)
    const end = endLabel ? after.toLowerCase().indexOf(endLabel.toLowerCase(), startLabel.length) : -1
    return end === -1 ? after : after.slice(0, end)
  }

  function parseSettingsHtml(html, nowIso) {
    if (String(html || "").indexOf("Cloud Usage") === -1) return null
    const text = textFromHtml(html)
    const percentages = []
    const re = /(\d+(?:\.\d+)?)%\s*used/gi
    let match
    while ((match = re.exec(text)) && percentages.length < 2) {
      percentages.push(clampPercent(match[1]))
    }
    if (percentages.length < 2 || percentages[0] === null || percentages[1] === null) return null

    const resetMatches = String(html).match(/data-time="([^"]+)"/g) || []
    const resetValues = resetMatches.map(function (s) {
      const m = /data-time="([^"]+)"/.exec(s)
      return m && m[1] ? m[1] : null
    })

    const planMatch = /Cloud Usage\s+(Free|Pro|Max|Team)\b/i.exec(text)
    const sessionSection = sectionBetween(text, "Session usage", "Weekly usage")
    const weeklySection = sectionBetween(text, "Weekly usage", "Notify me")
    return {
      plan: planMatch ? planMatch[1] : null,
      sessionPercent: percentages[0],
      weeklyPercent: percentages[1],
      sessionResetsAt: resetValues[0] || relativeResetIso(sessionSection, nowIso),
      weeklyResetsAt: resetValues[1] || relativeResetIso(weeklySection, nowIso),
      source: "settings",
    }
  }

  function fetchSettingsUsage(ctx, cookie) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: SETTINGS_URL,
        headers: {
          Accept: "text/html",
          Cookie: SESSION_COOKIE_NAME + "=" + cookie.value,
          "User-Agent": "OpenUsage",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      throw "Could not reach ollama.com. Check your connection."
    }

    if (resp.status === 302 || resp.status === 303 || resp.status === 307 || resp.status === 308) {
      throw "Ollama session expired. Update your session cookie."
    }
    if (ctx.util.isAuthStatus(resp.status)) throw "Ollama session expired. Update your session cookie."
    if (resp.status < 200 || resp.status >= 300) throw "Ollama settings request failed (HTTP " + resp.status + ")."

    const usage = parseSettingsHtml(resp.bodyText, ctx.nowIso)
    if (!usage) throw "Could not parse Ollama Cloud usage from settings."
    usage.source = cookie.source
    return usage
  }

  function formatPlan(value) {
    const plan = readString(value)
    if (!plan) return null
    return plan.charAt(0).toUpperCase() + plan.slice(1).toLowerCase()
  }

  function probe(ctx) {
    const cookie = loadSessionCookie(ctx)
    if (cookie) {
      return buildResult(ctx, fetchSettingsUsage(ctx, cookie))
    }

    const apiKey = loadApiKey(ctx)
    if (apiKey) {
      const apiUsage = parseApiUsage(
        requestJson(ctx, ACCOUNT_USAGE_URL, { Authorization: "Bearer " + apiKey, Accept: "application/json" })
      )
      if (apiUsage) return buildResult(ctx, apiUsage)
    }

    throw "Ollama auth missing. Set OLLAMA_SESSION_COOKIE or sign in with Firefox."
  }

  function buildResult(ctx, usage) {
    const sessionOpts = {
      label: "Session",
      used: usage.sessionPercent,
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: SESSION_MS,
    }
    if (usage.sessionResetsAt) sessionOpts.resetsAt = usage.sessionResetsAt

    const weeklyOpts = {
      label: "Weekly",
      used: usage.weeklyPercent,
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: WEEK_MS,
    }
    if (usage.weeklyResetsAt) weeklyOpts.resetsAt = usage.weeklyResetsAt

    return {
      plan: formatPlan(usage.plan),
      lines: [
        ctx.line.progress(sessionOpts),
        ctx.line.progress(weeklyOpts),
        ctx.line.text({ label: "Source", value: usage.source === "API" ? "Ollama API" : "Settings page" }),
      ],
    }
  }

  globalThis.__openusage_plugin = { id: "ollama", probe }
})()
