(function () {
  const AUTH_PATH = "~/.grok/auth.json"
  const BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing"
  const SETTINGS_URL = "https://cli-chat-proxy.grok.com/v1/settings"
  const TOKEN_AUTH_HEADER = "xai-grok-cli"
  const AUTH_REFRESH_BUFFER_MS = 5 * 60 * 1000

  function readJson(ctx, path) {
    if (!ctx.host.fs.exists(path)) return null
    try {
      return ctx.util.tryParseJson(ctx.host.fs.readText(path))
    } catch {
      return null
    }
  }

  function entryExpiresAtMs(ctx, entry) {
    if (!entry || typeof entry !== "object") return null
    if (!entry.expires_at) return null
    return ctx.util.parseDateMs(entry.expires_at)
  }

  function isExpired(ctx, entry, nowMs) {
    const expiresAtMs = entryExpiresAtMs(ctx, entry)
    if (expiresAtMs === null) return false
    return nowMs + AUTH_REFRESH_BUFFER_MS >= expiresAtMs
  }

  function loadAuth(ctx) {
    const auth = readJson(ctx, AUTH_PATH)
    if (!auth || typeof auth !== "object") {
      throw "Grok not logged in. Run `grok login`."
    }

    const nowMs = ctx.util.parseDateMs(ctx.nowIso) || Date.now()
    let expiredCandidate = false
    const keys = Object.keys(auth)
    for (let i = 0; i < keys.length; i++) {
      const entry = auth[keys[i]]
      if (!entry || typeof entry !== "object") continue
      const token = typeof entry.key === "string" ? entry.key.trim() : ""
      if (!token) continue
      if (isExpired(ctx, entry, nowMs)) {
        expiredCandidate = true
        continue
      }
      return { token }
    }

    if (expiredCandidate) {
      throw "Grok auth expired. Run `grok login` again."
    }
    throw "Grok auth invalid. Run `grok login` again."
  }

  function unitsValue(obj) {
    if (!obj || typeof obj !== "object") return null
    const n = Number(obj.val)
    return Number.isFinite(n) ? n : null
  }

  function clampPercent(value) {
    const n = Number(value)
    if (!Number.isFinite(n)) return 0
    if (n < 0) return 0
    if (n > 100) return 100
    return n
  }

  function fetchBilling(ctx, token) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: BILLING_URL,
        headers: {
          Authorization: "Bearer " + token,
          "X-XAI-Token-Auth": TOKEN_AUTH_HEADER,
          Accept: "application/json",
          "User-Agent": "OpenUsage",
        },
        timeoutMs: 10000,
      })
    } catch {
      throw "Grok billing request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Grok auth expired. Run `grok login` again."
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw "Grok billing request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    const data = ctx.util.tryParseJson(resp.bodyText)
    if (!data) {
      throw "Grok billing response changed."
    }
    return data
  }

  function fetchPlanName(ctx, token) {
    try {
      const resp = ctx.util.request({
        method: "GET",
        url: SETTINGS_URL,
        headers: {
          Authorization: "Bearer " + token,
          "X-XAI-Token-Auth": TOKEN_AUTH_HEADER,
          Accept: "application/json",
          "User-Agent": "OpenUsage",
        },
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) return null
      const data = ctx.util.tryParseJson(resp.bodyText)
      const plan = data && data.subscription_tier_display
      return typeof plan === "string" && plan.trim() ? plan.trim() : null
    } catch {
      return null
    }
  }

  function probe(ctx) {
    const auth = loadAuth(ctx)
    const data = fetchBilling(ctx, auth.token)
    const config = data && data.config
    if (!config || typeof config !== "object") {
      throw "Grok billing response changed."
    }

    const usedUnits = unitsValue(config.used)
    const limitUnits = unitsValue(config.monthlyLimit)
    const onDemandCapUnits = unitsValue(config.onDemandCap)
    if (usedUnits === null || limitUnits === null || limitUnits <= 0 || onDemandCapUnits === null) {
      throw "Grok billing response changed."
    }

    const resetsAt = ctx.util.toIso(config.billingPeriodEnd)
    if (!resetsAt) {
      throw "Grok billing response changed."
    }

    const usedPercent = clampPercent((usedUnits / limitUnits) * 100)
    const lines = [
      ctx.line.progress({
        label: "Credits used",
        used: usedPercent,
        limit: 100,
        format: { kind: "percent" },
        resetsAt,
      }),
      ctx.line.badge({
        label: "Pay as you go",
        text: onDemandCapUnits > 0 ? String(onDemandCapUnits) + " cap" : "Disabled",
        color: onDemandCapUnits > 0 ? "#22c55e" : "#a3a3a3",
      }),
    ]

    return { plan: fetchPlanName(ctx, auth.token), lines }
  }

  globalThis.__openusage_plugin = { id: "grok", probe }
})()
