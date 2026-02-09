(function () {
  const KEYCHAIN_SERVICE = "OpenUsage-zai"
  const BASE_URL = "https://open.bigmodel.cn"
  const SUBSCRIPTION_URL = BASE_URL + "/api/biz/subscription/list"
  const QUOTA_URL = BASE_URL + "/api/monitor/usage/quota/limit"
  const PERIOD_MS = 5 * 60 * 60 * 1000
  const MONTH_MS = 30 * 24 * 60 * 60 * 1000

  function loadApiKey(ctx) {
    try {
      const key = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE)
      if (key && String(key).trim()) return String(key).trim()
    } catch (e) {
      ctx.host.log.warn("keychain read failed: " + String(e))
    }
    return null
  }

  function fetchSubscription(ctx, apiKey) {
    try {
      const resp = ctx.util.request({
        method: "GET",
        url: SUBSCRIPTION_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("subscription request failed: HTTP " + resp.status)
        return null
      }
      const data = ctx.util.tryParseJson(resp.bodyText)
      if (!data) return null
      const list = data.data
      if (!Array.isArray(list) || list.length === 0) return null
      return {
        productName: list[0].productName || null,
        nextRenewTime: list[0].nextRenewTime || null,
      }
    } catch (e) {
      ctx.host.log.warn("subscription request exception: " + String(e))
      return null
    }
  }

  function fetchQuota(ctx, apiKey) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: QUOTA_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      ctx.host.log.error("usage request exception: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "API key invalid. Check your Z.ai API key."
    }

    if (resp.status < 200 || resp.status >= 300) {
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    const data = ctx.util.tryParseJson(resp.bodyText)
    if (!data) {
      throw "Usage response invalid. Try again later."
    }

    return data
  }

  function findLimit(limits, type) {
    for (let i = 0; i < limits.length; i++) {
      if (limits[i].type === type || limits[i].name === type) return limits[i]
    }
    return null
  }

  function probe(ctx) {
    const apiKey = loadApiKey(ctx)
    if (!apiKey) {
      throw 'API key not configured. Store it with: `security add-generic-password -s OpenUsage-zai -a OpenUsage -w "YOUR_KEY" -U`'
    }

    const sub = fetchSubscription(ctx, apiKey)
    const plan = sub && sub.productName ? ctx.fmt.planLabel(sub.productName) : null

    const quota = fetchQuota(ctx, apiKey)
    const lines = []

    const container = quota.data || quota
    const limits = container.limits || container
    if (!Array.isArray(limits) || limits.length === 0) {
      lines.push(ctx.line.badge({ label: "Session", text: "No usage data", color: "#a3a3a3" }))
      return { plan, lines }
    }

    const tokenLimit = findLimit(limits, "TOKENS_LIMIT")

    if (!tokenLimit) {
      lines.push(ctx.line.badge({ label: "Session", text: "No usage data", color: "#a3a3a3" }))
      return { plan, lines }
    }

    const used = typeof tokenLimit.percentage === "number" ? tokenLimit.percentage : 0
    const resetsAt = tokenLimit.nextResetTime ? ctx.util.toIso(tokenLimit.nextResetTime) : undefined

    const progressOpts = {
      label: "Session",
      used,
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: PERIOD_MS,
    }
    if (resetsAt) {
      progressOpts.resetsAt = resetsAt
    }
    lines.push(ctx.line.progress(progressOpts))

    const timeLimit = findLimit(limits, "TIME_LIMIT")

    if (timeLimit) {
      const webUsed = typeof timeLimit.currentValue === "number" ? timeLimit.currentValue : 0
      const webTotal = typeof timeLimit.usage === "number" ? timeLimit.usage : 0
      const now = new Date()
      const nextMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1))
      const webResetsAt = timeLimit.nextResetTime
        ? ctx.util.toIso(timeLimit.nextResetTime)
        : nextMonth.toISOString()

      const webOpts = {
        label: "Web Searches",
        used: webUsed,
        limit: webTotal,
        format: { kind: "count", suffix: "/ " + webTotal },
        periodDurationMs: MONTH_MS,
      }
      if (webResetsAt) {
        webOpts.resetsAt = webResetsAt
      }
      lines.push(ctx.line.progress(webOpts))
    }

    return { plan, lines }
  }

  globalThis.__openusage_plugin = { id: "zai", probe }
})()
