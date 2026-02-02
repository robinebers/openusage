(function () {
  const STATE_DB =
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  const BASE_URL = "https://api2.cursor.sh"
  const USAGE_URL = BASE_URL + "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
  const PLAN_URL = BASE_URL + "/aiserver.v1.DashboardService/GetPlanInfo"

  function lineText(label, value, color) {
    const line = { type: "text", label, value }
    if (color) line.color = color
    return line
  }

  function lineProgress(label, value, max, unit, color) {
    return { type: "progress", label, value, max, unit, color }
  }

  function lineBadge(label, text, color) {
    const line = { type: "badge", label, text }
    if (color) line.color = color
    return line
  }

  function formatPlanLabel(value) {
    const text = String(value || "").trim()
    if (!text) return ""
    return text.replace(/(^|\s)([a-z])/g, function (match, space, letter) {
      return space + letter.toUpperCase()
    })
  }

  function readStateValue(ctx, key) {
    try {
      const sql =
        "SELECT value FROM ItemTable WHERE key = '" + key + "' LIMIT 1;"
      const json = ctx.host.sqlite.query(STATE_DB, sql)
      const rows = JSON.parse(json)
      if (rows.length > 0 && rows[0].value) {
        return rows[0].value
      }
    } catch (e) {
      ctx.host.log.warn("sqlite read failed for " + key + ": " + String(e))
    }
    return null
  }

  function connectPost(ctx, url, token) {
    return ctx.host.http.request({
      method: "POST",
      url: url,
      headers: {
        Authorization: "Bearer " + token,
        "Content-Type": "application/json",
        "Connect-Protocol-Version": "1",
      },
      bodyText: "{}",
      timeoutMs: 10000,
    })
  }

  function dollarsFromCents(cents) {
    const d = cents / 100
    return Math.round(d * 100) / 100
  }

  function formatResetDate(unixMs) {
    const d = new Date(Number(unixMs))
    const months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    return months[d.getMonth()] + " " + String(d.getDate())
  }

  function probe(ctx) {
    const accessToken = readStateValue(ctx, "cursorAuth/accessToken")
    if (!accessToken) {
      return { lines: [lineBadge("Status", "Login required", "#f59e0b")] }
    }

    let usageResp
    try {
      usageResp = connectPost(ctx, USAGE_URL, accessToken)
    } catch (e) {
      return { lines: [lineBadge("Error", "usage request failed", "#ef4444")] }
    }

    if (usageResp.status === 401 || usageResp.status === 403) {
      return { lines: [lineBadge("Status", "Token expired", "#f59e0b")] }
    }

    if (usageResp.status < 200 || usageResp.status >= 300) {
      return { lines: [lineBadge("Error", "HTTP " + String(usageResp.status), "#ef4444")] }
    }

    let usage
    try {
      usage = JSON.parse(usageResp.bodyText)
    } catch {
      return { lines: [lineBadge("Error", "cannot parse usage response", "#ef4444")] }
    }

    if (!usage.enabled || !usage.planUsage) {
      return { lines: [lineBadge("Status", "Usage tracking disabled", "#f59e0b")] }
    }

    let planName = ""
    try {
      const planResp = connectPost(ctx, PLAN_URL, accessToken)
      if (planResp.status >= 200 && planResp.status < 300) {
        const plan = JSON.parse(planResp.bodyText)
        if (plan.planInfo && plan.planInfo.planName) {
          planName = plan.planInfo.planName
        }
      }
    } catch (e) {
      ctx.host.log.warn("plan info fetch failed: " + String(e))
    }

    const lines = []
    if (planName) {
      const planLabel = formatPlanLabel(planName)
      if (planLabel) {
        lines.push(lineBadge("Plan", planLabel, "#000000"))
      }
    }

    const pu = usage.planUsage
    lines.push(
      lineProgress("Plan usage", dollarsFromCents(pu.totalSpend), dollarsFromCents(pu.limit), "dollars")
    )

    if (typeof pu.bonusSpend === "number" && pu.bonusSpend > 0) {
      lines.push(lineText("Bonus spend", "$" + String(dollarsFromCents(pu.bonusSpend))))
    }

    const su = usage.spendLimitUsage
    if (su) {
      const limit = su.individualLimit ?? su.pooledLimit ?? 0
      const remaining = su.individualRemaining ?? su.pooledRemaining ?? 0
      if (limit > 0) {
        const used = limit - remaining
        lines.push(
          lineProgress("On-demand", dollarsFromCents(used), dollarsFromCents(limit), "dollars")
        )
      }
    }

    if (usage.billingCycleEnd) {
      lines.push(lineText("Resets", formatResetDate(usage.billingCycleEnd)))
    }

    return { lines }
  }

  globalThis.__openusage_plugin = { id: "cursor", probe }
})()
