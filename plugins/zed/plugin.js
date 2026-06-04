(function () {
  const PROVIDER_ID = "zed"
  const CLOUD_BASE_URL = "https://cloud.zed.dev"
  const DASHBOARD_BASE_URL = "https://dashboard.zed.dev"
  const ZED_SERVER_URL = "https://zed.dev"
  const BILLING_USAGE_URL = CLOUD_BASE_URL + "/frontend/billing/usage"
  const BILLING_TOKENS_URL = CLOUD_BASE_URL + "/frontend/billing/usage/tokens"
  const USER_URL = CLOUD_BASE_URL + "/client/users/me"
  const MONTH_MS = 30 * 24 * 60 * 60 * 1000

  function readEnvText(ctx, name) {
    try {
      if (!ctx.host.env || typeof ctx.host.env.get !== "function") return null
      const value = ctx.host.env.get(name)
      if (value === null || value === undefined) return null
      const text = String(value).trim()
      return text || null
    } catch {
      return null
    }
  }

  function loadEnvCredentials(ctx) {
    const userId = readEnvText(ctx, "ZED_USER_ID")
    const accessToken = readEnvText(ctx, "ZED_ACCESS_TOKEN")
    if (!userId || !accessToken) return null
    return { userId, accessToken }
  }

  function loadKeychainCredentials(ctx) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readInternetPassword !== "function") {
      return null
    }

    try {
      const item = ctx.host.keychain.readInternetPassword(ZED_SERVER_URL)
      if (!item) return null
      const userId = String(item.account || "").trim()
      const accessToken = String(item.password || "").trim()
      if (!userId || !accessToken) return null
      return { userId, accessToken }
    } catch (e) {
      ctx.host.log.warn("Zed keychain lookup failed: " + String(e))
      return null
    }
  }

  function loadCredentials(ctx) {
    const env = loadEnvCredentials(ctx)
    if (env) return env

    const keychain = loadKeychainCredentials(ctx)
    if (keychain) return keychain

    throw "Zed login required. Sign in to Zed, then try again."
  }

  function authHeader(credentials) {
    return credentials.userId + " " + credentials.accessToken
  }

  function requestJson(ctx, credentials, url, opts) {
    const soft = opts && opts.soft
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url,
        headers: {
          Authorization: authHeader(credentials),
          Accept: "application/json",
          "Content-Type": "application/json",
        },
        timeoutMs: 10000,
      })
    } catch (e) {
      if (soft) {
        ctx.host.log.warn("Zed request failed: " + String(e))
        return null
      }
      throw "Zed usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      if (soft) return null
      throw "Zed session expired. Sign in to Zed, then try again."
    }

    if (resp.status < 200 || resp.status >= 300) {
      if (soft) {
        ctx.host.log.warn("Zed request failed: HTTP " + String(resp.status))
        return null
      }
      throw "Zed usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }

    const data = ctx.util.tryParseJson(resp.bodyText)
    if (!data) {
      if (soft) return null
      throw "Zed usage response invalid. Try again later."
    }
    return data
  }

  function numberOrNull(value) {
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function textOrNull(value) {
    if (value === null || value === undefined || typeof value === "object") return null
    const text = String(value).trim()
    return text || null
  }

  function firstDefined(a, b) {
    return a === null || a === undefined ? b : a
  }

  function centsToDollars(value) {
    const cents = numberOrNull(value)
    if (cents === null) return null
    return Math.round((cents / 100) * 100) / 100
  }

  function formatDollars(value) {
    const n = numberOrNull(value)
    if (n === null) return "$0.00"
    return "$" + n.toFixed(2)
  }

  function formatCount(value) {
    const n = numberOrNull(value)
    if (n === null) return "0"
    return String(Math.round(n))
  }

  function parseLimit(value) {
    if (value === null || value === undefined) return null
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    if (typeof value === "string") {
      const text = value.trim().toLowerCase()
      if (!text || text === "unlimited") return null
      return numberOrNull(text)
    }
    if (typeof value === "object") {
      if (Object.prototype.hasOwnProperty.call(value, "limited")) {
        return numberOrNull(value.limited)
      }
      if (Object.prototype.hasOwnProperty.call(value, "limit")) {
        return parseLimit(value.limit)
      }
      if (Object.prototype.hasOwnProperty.call(value, "value")) {
        return numberOrNull(value.value)
      }
    }
    return null
  }

  function parseDateMs(value) {
    if (value === null || value === undefined) return null
    if (typeof value === "number") {
      if (!Number.isFinite(value)) return null
      return Math.abs(value) < 1e10 ? value * 1000 : value
    }
    const parsed = Date.parse(String(value))
    return Number.isFinite(parsed) ? parsed : null
  }

  function planLabel(ctx, value) {
    if (value === null || value === undefined) return null
    let text = String(value).trim()
    if (!text) return null
    text = text.replace(/[_-]+/g, " ")
    return ctx.fmt.planLabel(text)
  }

  function extractPlan(ctx, frontendUsage, clientUser) {
    const frontendPlan = frontendUsage && frontendUsage.plan
    if (frontendPlan) return planLabel(ctx, frontendPlan)

    const planInfo = clientUser && clientUser.plan
    if (!planInfo) return null
    return planLabel(ctx, planInfo.plan_v3 || planInfo.plan)
  }

  function extractCurrentUsage(frontendUsage) {
    if (!frontendUsage) return null
    return frontendUsage.current_usage || frontendUsage.currentUsage || null
  }

  function extractClientEditUsage(clientUser) {
    const plan = clientUser && clientUser.plan
    const usage = plan && plan.usage
    return usage && usage.edit_predictions ? usage.edit_predictions : null
  }

  function extractClientPeriod(clientUser) {
    const plan = clientUser && clientUser.plan
    return plan && plan.subscription_period ? plan.subscription_period : null
  }

  function organizationIdFromClientUser(clientUser) {
    if (!clientUser) return null

    const defaultOrganizationId = firstDefined(
      clientUser.default_organization_id,
      clientUser.defaultOrganizationId
    )
    const directId = textOrNull(defaultOrganizationId)
    if (directId) return directId

    const organizations = clientUser.organizations
    if (!Array.isArray(organizations)) return null
    for (let i = 0; i < organizations.length; i++) {
      const org = organizations[i]
      if (!org || typeof org !== "object") continue
      const id = textOrNull(firstDefined(org.id, firstDefined(org.organization_id, org.organizationId)))
      if (id) return id
    }
    return null
  }

  function usageLinks(clientUser) {
    const organizationId = organizationIdFromClientUser(clientUser)
    if (!organizationId) return []
    return [{
      label: "AI Usage",
      url: DASHBOARD_BASE_URL + "/" + encodeURIComponent(organizationId) + "/billing/usage",
    }]
  }

  function periodMeta(ctx, period) {
    if (!period) return {}
    const startedMs = parseDateMs(period.started_at || period.startedAt)
    const endedMs = parseDateMs(period.ended_at || period.endedAt)
    const meta = {}
    if (endedMs !== null) meta.resetsAt = ctx.util.toIso(endedMs)
    if (startedMs !== null && endedMs !== null && endedMs > startedMs) {
      meta.periodDurationMs = endedMs - startedMs
    }
    return meta
  }

  function pushTokenSpendLine(ctx, lines, currentUsage) {
    const tokenSpend = currentUsage && (currentUsage.token_spend || currentUsage.tokenSpend)
    if (!tokenSpend) return

    const spent = centsToDollars(firstDefined(tokenSpend.spend_in_cents, tokenSpend.spendInCents))
    if (spent === null) return

    const limit = centsToDollars(firstDefined(tokenSpend.limit_in_cents, tokenSpend.limitInCents))
    if (limit !== null && limit > 0) {
      lines.push(ctx.line.progress({
        label: "Token Spend",
        used: spent,
        limit,
        format: { kind: "dollars" },
        periodDurationMs: MONTH_MS,
      }))
      return
    }

    lines.push(ctx.line.text({
      label: "Token Spend",
      value: formatDollars(spent),
    }))
  }

  function pushEditPredictionLine(ctx, lines, editUsage, period) {
    if (!editUsage) return
    const used = numberOrNull(editUsage.used)
    const limit = parseLimit(editUsage.limit)
    const meta = periodMeta(ctx, period)

    if (used !== null && limit !== null && limit > 0) {
      const opts = {
        label: "Edit Predictions",
        used,
        limit,
        format: { kind: "count", suffix: "/ " + formatCount(limit) },
      }
      if (meta.resetsAt) opts.resetsAt = meta.resetsAt
      if (meta.periodDurationMs) opts.periodDurationMs = meta.periodDurationMs
      lines.push(ctx.line.progress(opts))
      return
    }

    if (used !== null) {
      lines.push(ctx.line.text({
        label: "Edit Predictions",
        value: formatCount(used) + " used",
      }))
    }
  }

  function pushUpdatedLine(ctx, lines, currentUsage, tokenUsage) {
    const tokenSpend = currentUsage && (currentUsage.token_spend || currentUsage.tokenSpend)
    const updatedAt =
      (tokenSpend && firstDefined(tokenSpend.updated_at, tokenSpend.updatedAt)) ||
      (tokenUsage && firstDefined(tokenUsage.usage_cache_updated_at, tokenUsage.usageCacheUpdatedAt))
    const updatedMs = parseDateMs(updatedAt)
    if (updatedMs === null) return
    lines.push(ctx.line.text({
      label: "Updated",
      value: ctx.fmt.date(updatedMs),
    }))
  }

  function pushDailySpendLine(ctx, lines, tokenUsage) {
    const totalUsage = tokenUsage && (tokenUsage.total_usage || tokenUsage.totalUsage)
    if (!Array.isArray(totalUsage) || totalUsage.length === 0) return

    const points = []
    for (let i = 0; i < totalUsage.length; i++) {
      const day = totalUsage[i]
      if (!day) continue
      const dateMs = parseDateMs(day.date)
      if (dateMs === null) continue
      let amount = centsToDollars(firstDefined(day.spend_in_cents, day.spendInCents))
      if (amount === null) amount = centsToDollars(firstDefined(day.cost_in_cents, day.costInCents))
      if (amount === null || amount < 0) continue
      points.push({
        key: new Date(dateMs).toISOString().slice(0, 10),
        label: ctx.fmt.date(dateMs),
        value: amount,
        valueLabel: formatDollars(amount),
      })
    }

    const sorted = points
      .sort((a, b) => a.key.localeCompare(b.key))
      .slice(-31)
      .map((point) => ({
        label: point.label,
        value: point.value,
        valueLabel: point.valueLabel,
      }))

    if (sorted.length === 0) return
    lines.push(ctx.line.barChart({
      label: "Daily Spend",
      points: sorted,
      color: "#1348DC",
    }))
  }

  function probe(ctx) {
    const credentials = loadCredentials(ctx)

    const clientUser = requestJson(ctx, credentials, USER_URL, { soft: false })
    const frontendUsage = requestJson(ctx, credentials, BILLING_USAGE_URL, { soft: true })
    const currentUsage = extractCurrentUsage(frontendUsage)
    const tokenUsage = frontendUsage
      ? requestJson(ctx, credentials, BILLING_TOKENS_URL, { soft: true })
      : null

    const frontendEditUsage = currentUsage && (currentUsage.edit_predictions || currentUsage.editPredictions)

    const lines = []
    const plan = extractPlan(ctx, frontendUsage, clientUser)
    const links = usageLinks(clientUser)

    if (currentUsage) {
      pushTokenSpendLine(ctx, lines, currentUsage)
      pushEditPredictionLine(ctx, lines, frontendEditUsage, null)
      pushUpdatedLine(ctx, lines, currentUsage, tokenUsage)
    }

    if (!frontendEditUsage) {
      pushEditPredictionLine(ctx, lines, extractClientEditUsage(clientUser), extractClientPeriod(clientUser))
    }

    pushDailySpendLine(ctx, lines, tokenUsage)

    const planInfo = clientUser && clientUser.plan
    if (planInfo && planInfo.has_overdue_invoices) {
      lines.push(ctx.line.badge({ label: "Status", text: "Invoice overdue", color: "#f97316" }))
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan, lines, links }
  }

  globalThis.__openusage_plugin = { id: PROVIDER_ID, probe }
})()
