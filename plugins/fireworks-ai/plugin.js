(function () {
  const API_BASE = "https://api.fireworks.ai/v1"
  const ACCOUNTS_URL = API_BASE + "/accounts?pageSize=200"
  const KEYCHAIN_SERVICE = "OpenUsage Fireworks AI API Key"
  const ENV_VAR = "FIREWORKS_API_KEY"
  const BILLING_WINDOW_DAYS = 30
  const TIER_BY_CAP = { 50: "Tier 1", 500: "Tier 2", 5000: "Tier 3", 50000: "Tier 4" }
  const HEALTHY_STATES = ["READY", "ACTIVE", "STATE_UNSPECIFIED"]
  const HEALTHY_SUSPEND = ["UNSUSPENDED", "SUSPEND_STATE_UNSPECIFIED", null]
  const TOTAL_TOKENS_NAMES = ["serverless-inference-total-tokens", "serverless-inference-tokens", "serverless-usage-tokens"]

  function text(value) {
    if (typeof value !== "string") return null
    const trimmed = value.trim()
    return trimmed || null
  }

  function num(value) {
    if (typeof value === "number") return Number.isFinite(value) ? value : null
    const raw = text(value)
    if (!raw) return null
    const parsed = Number(raw)
    return Number.isFinite(parsed) ? parsed : null
  }

  function title(value) {
    const raw = text(value)
    return raw ? raw.replace(/[_-]+/g, " ").replace(/\b[a-z]/g, (m) => m.toUpperCase()) : null
  }

  function lastPathPart(value) {
    const raw = text(value)
    return raw ? raw.split("/").filter(Boolean).pop() || null : null
  }

  function lastFinite(values) {
    for (let i = 0; i < values.length; i += 1) {
      if (Number.isFinite(values[i])) return values[i]
    }
    return null
  }

  function formatGroupedNumber(value) {
    const parts = String(value).split(".")
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return parts.join(".")
  }

  function formatFixed(value, decimals) {
    const scale = Math.pow(10, decimals)
    const rounded = Math.round(value * scale) / scale
    const fixed = String(rounded.toFixed(decimals))
    return decimals > 0 ? fixed.replace(/\.?0+$/, "") : fixed
  }

  function formatDollars(value) {
    if (!Number.isFinite(value)) return null
    const rounded = Math.round(value * 100) / 100
    const fixed = formatFixed(rounded, rounded % 1 === 0 ? 0 : 2)
    const parts = fixed.split(".")
    return "$" + formatGroupedNumber(parts.join("."))
  }

  function formatCompactCount(value) {
    if (!Number.isFinite(value)) return null
    const abs = Math.abs(value)
    const units = [{ threshold: 1e12, suffix: "T" }, { threshold: 1e9, suffix: "B" }, { threshold: 1e6, suffix: "M" }, { threshold: 1e3, suffix: "K" }]
    for (let i = 0; i < units.length; i += 1) {
      const unit = units[i]
      if (abs >= unit.threshold) return formatFixed(value / unit.threshold, 2) + unit.suffix
    }
    return formatGroupedNumber(String(Math.round(value)))
  }

  function startOfUtcDayMs(ms) {
    const date = new Date(ms)
    return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate())
  }

  function buildBillingWindow(nowMs) {
    const endMs = startOfUtcDayMs(nowMs) + 24 * 60 * 60 * 1000
    const startMs = endMs - BILLING_WINDOW_DAYS * 24 * 60 * 60 * 1000
    const fmt = (ms) => new Date(ms).toISOString().slice(0, 10)
    return { startTime: fmt(startMs), endTime: fmt(endMs), label: "Last " + BILLING_WINDOW_DAYS + " days" }
  }

  function parseCsvRow(text) {
    const out = []
    let current = ""
    let inQuotes = false
    for (let i = 0; i < text.length; i += 1) {
      const char = text.charAt(i)
      if (char === '"') {
        if (inQuotes && text.charAt(i + 1) === '"') {
          current += '"'
          i += 1
        } else {
          inQuotes = !inQuotes
        }
      } else if (char === "," && !inQuotes) {
        out.push(current)
        current = ""
      } else {
        current += char
      }
    }
    out.push(current)
    return out
  }

  function parseBillingMetricsCsv(text) {
    const raw = text && String(text).trim()
    if (!raw) return []
    const lines = raw.split(/\r?\n/).filter(Boolean)
    if (lines.length < 2) return []
    const header = parseCsvRow(lines[0]).map((value) => value.trim())
    const rows = []
    for (let i = 1; i < lines.length; i += 1) {
      const cols = parseCsvRow(lines[i])
      if (!cols.length) continue
      const row = {}
      for (let j = 0; j < header.length; j += 1) row[header[j]] = cols[j] || ""
      rows.push(row)
    }
    return rows
  }

  function readKeychainApiKey(ctx) {
    const keychain = ctx.host.keychain
    if (!keychain) return null
    if (typeof keychain.readGenericPasswordForCurrentUser === "function") {
      try {
        const value = text(keychain.readGenericPasswordForCurrentUser(KEYCHAIN_SERVICE))
        if (value) return { value, source: "keychain-current-user" }
      } catch (e) {
        ctx.host.log.info("current-user keychain read failed, trying legacy lookup: " + String(e))
      }
    }
    if (typeof keychain.readGenericPassword !== "function") return null
    try {
      const value = text(keychain.readGenericPassword(KEYCHAIN_SERVICE))
      return value ? { value, source: "keychain-legacy" } : null
    } catch (e) {
      ctx.host.log.info("keychain read failed (may not exist): " + String(e))
      return null
    }
  }

  function loadApiKey(ctx) {
    const keychainValue = readKeychainApiKey(ctx)
    if (keychainValue) return keychainValue
    try {
      const value = text(ctx.host.env.get(ENV_VAR))
      return value ? { value, source: ENV_VAR } : null
    } catch (e) {
      ctx.host.log.warn("env read failed for " + ENV_VAR + ": " + String(e))
      return null
    }
  }

  function requestJson(ctx, apiKey, url) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
          "User-Agent": "OpenUsage/" + String(ctx.app && ctx.app.version ? ctx.app.version : "0.0.0"),
        },
        timeoutMs: 15000,
      })
    } catch (e) {
      ctx.host.log.error("request failed: " + String(e))
      throw "Request failed. Check your connection."
    }
    if (ctx.util.isAuthStatus(resp.status)) throw "API key invalid. Check your Fireworks AI API key."
    if (resp.status < 200 || resp.status >= 300) throw "Request failed (HTTP " + resp.status + "). Try again later."
    const parsed = ctx.util.tryParseJson(resp.bodyText)
    if (!parsed || typeof parsed !== "object") throw "Response invalid. Try again later."
    return parsed
  }

  function listAccounts(ctx, apiKey) {
    const parsed = requestJson(ctx, apiKey, ACCOUNTS_URL)
    const accounts = Array.isArray(parsed.accounts) ? parsed.accounts : Array.isArray(parsed.data) ? parsed.data : null
    if (!accounts || !accounts.length) throw "No Fireworks account found for this API key."
    return accounts
  }

  function pickAccount(accounts) {
    let fallback = null
    for (let i = 0; i < accounts.length; i += 1) {
      const item = accounts[i]
      if (!item || typeof item !== "object") continue
      const accountId = lastPathPart(item.name) || text(item.accountId) || text(item.account_id)
      if (!accountId) continue
      const account = {
        accountId,
        state: text(item.state),
        suspendState: text(item.suspendState || item.suspend_state),
      }
      if (!fallback) fallback = account
      if (HEALTHY_STATES.includes(account.state) && HEALTHY_SUSPEND.includes(account.suspendState)) return account
    }
    return fallback
  }

  function listQuotas(ctx, apiKey, accountId) {
    const parsed = requestJson(ctx, apiKey, API_BASE + "/accounts/" + encodeURIComponent(accountId) + "/quotas?pageSize=200")
    return Array.isArray(parsed.quotas) ? parsed.quotas : Array.isArray(parsed.data) ? parsed.data : []
  }

  function normalizeQuota(ctx, raw) {
    if (!raw || typeof raw !== "object") return null
    const name = lastPathPart(raw.name) || text(raw.quotaId) || text(raw.id)
    if (!name) return null
    return {
      name,
      value: num(raw.value),
      maxValue: num(raw.maxValue || raw.max_value),
      usage: lastFinite([
        num(raw.usage),
        num(raw.currentUsage || raw.current_usage),
        num(raw.consumedValue || raw.consumed_value),
      ]),
      updateTime: ctx.util.toIso(raw.updateTime || raw.update_time),
    }
  }

  function findQuota(quotas, exactNames, pattern) {
    for (let i = 0; i < quotas.length; i += 1) {
      const quota = quotas[i]
      if (!quota) continue
      if (exactNames.includes(quota.name)) return quota
    }
    for (let i = 0; i < quotas.length; i += 1) {
      const quota = quotas[i]
      if (!quota) continue
      if (pattern.test(quota.name)) return quota
    }
    return null
  }

  function inferPlan(spendQuota) {
    if (!spendQuota || spendQuota.maxValue === null) return null
    const cap = Math.round(spendQuota.maxValue)
    return TIER_BY_CAP[cap] || null
  }

  function buildStatusLine(ctx, account) {
    const suspendState = account && account.suspendState
    if (suspendState && !HEALTHY_SUSPEND.includes(suspendState)) {
      return ctx.line.badge({ label: "Status", text: title(suspendState) || suspendState, color: "#f97316" })
    }
    const state = account && account.state
    if (state && !HEALTHY_STATES.includes(state)) {
      return ctx.line.badge({ label: "Status", text: title(state) || state, color: "#f97316" })
    }
    return null
  }

  function tokenAmount(quota) {
    if (!quota) return null
    if (quota.usage !== null && quota.usage >= 0) return quota.usage
    if (quota.maxValue === null && quota.value !== null && quota.value >= 0) return quota.value
    return null
  }

  function loadBillingUsage(ctx, apiKey, accountId, nowMs) {
    const fireworks = ctx.host.fireworks
    if (!fireworks || typeof fireworks.exportBillingMetrics !== "function") return { status: "unsupported" }
    const window = buildBillingWindow(nowMs)
    let exported
    try {
      exported = fireworks.exportBillingMetrics({
        apiKey,
        accountId,
        startTime: window.startTime,
        endTime: window.endTime,
      })
    } catch (e) {
      ctx.host.log.warn("billing export failed: " + String(e))
      return { status: "runner_failed" }
    }
    if (!exported || typeof exported.status !== "string") return { status: "runner_failed" }
    if (exported.status !== "ok" || !text(exported.csv)) return { status: exported.status }
    const rows = parseBillingMetricsCsv(exported.csv)
    let promptTokens = 0
    let generatedTokens = 0
    for (let i = 0; i < rows.length; i += 1) {
      const row = rows[i]
      const usageType = text(row.usage_type || row.usageType)
      if (usageType && !/inference_usage/i.test(usageType)) continue
      promptTokens += num(row.prompt_tokens || row.promptTokens) || 0
      generatedTokens += num(row.completion_tokens || row.completionTokens) || 0
    }
    const totalTokens = promptTokens + generatedTokens
    return totalTokens > 0
      ? { status: "ok", label: window.label, promptTokens, generatedTokens, totalTokens }
      : { status: "empty" }
  }

  function buildOutput(ctx, account, quotas, billingUsage) {
    const spendQuota = findQuota(quotas, ["monthly-spend-usd"], /^monthly-spend-usd$/)
    const totalTokensQuota = findQuota(quotas, TOTAL_TOKENS_NAMES, /(serverless|inference).*(total|usage).*tokens/i)
    const plan = inferPlan(spendQuota)
    const lines = []

    const promptTotal = billingUsage && billingUsage.status === "ok" ? billingUsage.promptTokens : null
    const generatedTotal = billingUsage && billingUsage.status === "ok" ? billingUsage.generatedTokens : null
    const totalTokens = (billingUsage && billingUsage.status === "ok" && billingUsage.totalTokens) || tokenAmount(totalTokensQuota) || null
    if (totalTokens !== null && totalTokens > 0) {
      lines.push(ctx.line.text({ label: "Serverless usage", value: formatCompactCount(totalTokens) + " tokens", subtitle: billingUsage && billingUsage.status === "ok" ? billingUsage.label : "Tokens reported by Fireworks" }))
    } else if (billingUsage && billingUsage.status !== "ok") {
      const reason =
        billingUsage.status === "no_runner" || billingUsage.status === "unsupported"
          ? "Install firectl for official billing export"
          : billingUsage.status === "runner_failed"
            ? "Billing export failed; showing spend fallback"
            : "Token totals not exposed for this account"
      lines.push(ctx.line.text({ label: "Serverless usage", value: "Unavailable", subtitle: reason }))
    }

    if (promptTotal !== null && promptTotal > 0) {
      lines.push(ctx.line.text({ label: "Prompt tokens", value: formatCompactCount(promptTotal) + " tokens", subtitle: billingUsage && billingUsage.status === "ok" ? billingUsage.label : "Tokens reported by Fireworks" }))
    }

    if (generatedTotal !== null && generatedTotal > 0) {
      lines.push(ctx.line.text({ label: "Generated tokens", value: formatCompactCount(generatedTotal) + " tokens", subtitle: billingUsage && billingUsage.status === "ok" ? billingUsage.label : "Tokens reported by Fireworks" }))
    }

    if (spendQuota && spendQuota.usage !== null && spendQuota.usage >= 0) {
      const spendSubtitle =
        spendQuota.value !== null && spendQuota.value > 0
          ? "This month against budget " + formatDollars(spendQuota.value)
          : "Calendar month to date"
      lines.push(ctx.line.text({ label: "Month spend", value: formatDollars(spendQuota.usage), subtitle: spendSubtitle }))
    }

    if (spendQuota && spendQuota.maxValue !== null && spendQuota.maxValue > 0) {
      const budgetValue = spendQuota.value !== null && spendQuota.value > 0 ? formatDollars(spendQuota.value) : "Not set"
      lines.push(ctx.line.text({ label: "Budget", value: budgetValue, subtitle: "Tier cap " + formatDollars(spendQuota.maxValue) }))
    }

    const statusLine = buildStatusLine(ctx, account)
    if (statusLine) lines.push(statusLine)

    if (!lines.length) lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    return { plan, lines }
  }

  function probe(ctx) {
    const nowMs = ctx.util.parseDateMs(ctx.nowIso) || Date.now()
    const apiKey = loadApiKey(ctx)
    if (!apiKey) {
      throw 'No Fireworks API key found. Save it in macOS Keychain as "OpenUsage Fireworks AI API Key" or set FIREWORKS_API_KEY, then restart OpenUsage.'
    }
    ctx.host.log.info("api key loaded from " + apiKey.source)
    const account = pickAccount(listAccounts(ctx, apiKey.value))
    if (!account) throw "No Fireworks account found for this API key."
    const quotas = listQuotas(ctx, apiKey.value, account.accountId).map((item) => normalizeQuota(ctx, item)).filter(Boolean)
    const billingUsage = loadBillingUsage(ctx, apiKey.value, account.accountId, nowMs)
    return buildOutput(ctx, account, quotas, billingUsage)
  }

  globalThis.__openusage_plugin = { id: "fireworks-ai", probe }
})()
