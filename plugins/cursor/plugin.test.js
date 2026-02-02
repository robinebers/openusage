import { beforeEach, describe, expect, it, vi } from "vitest"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const b64decode = (str) => {
  str = str.replace(/-/g, "+").replace(/_/g, "/")
  while (str.length % 4) str += "="
  str = str.replace(/=+$/, "")
  let result = ""
  const len = str.length
  let i = 0
  while (i < len) {
    const remaining = len - i
    const a = b64chars.indexOf(str.charAt(i++))
    const b = b64chars.indexOf(str.charAt(i++))
    const c = remaining > 2 ? b64chars.indexOf(str.charAt(i++)) : 0
    const d = remaining > 3 ? b64chars.indexOf(str.charAt(i++)) : 0
    const n = (a << 18) | (b << 12) | (c << 6) | d
    result += String.fromCharCode((n >> 16) & 0xff)
    if (remaining > 2) result += String.fromCharCode((n >> 8) & 0xff)
    if (remaining > 3) result += String.fromCharCode(n & 0xff)
  }
  return result
}

const makeCtx = () => ({
  host: {
    sqlite: { query: vi.fn(), exec: vi.fn() },
    http: { request: vi.fn() },
    log: { warn: vi.fn() },
  },
  line: {
    text: (opts) => {
      const line = { type: "text", label: opts.label, value: opts.value }
      if (opts.color) line.color = opts.color
      if (opts.subtitle) line.subtitle = opts.subtitle
      return line
    },
    progress: (opts) => {
      const line = { type: "progress", label: opts.label, value: opts.value, max: opts.max }
      if (opts.unit) line.unit = opts.unit
      if (opts.color) line.color = opts.color
      if (opts.subtitle) line.subtitle = opts.subtitle
      return line
    },
    badge: (opts) => {
      const line = { type: "badge", label: opts.label, text: opts.text }
      if (opts.color) line.color = opts.color
      if (opts.subtitle) line.subtitle = opts.subtitle
      return line
    },
  },
  fmt: {
    planLabel: (value) => {
      const text = String(value || "").trim()
      if (!text) return ""
      return text.replace(/(^|\s)([a-z])/g, (match, space, letter) => space + letter.toUpperCase())
    },
    resetIn: (secondsUntil) => {
      if (!Number.isFinite(secondsUntil) || secondsUntil < 0) return null
      const totalMinutes = Math.floor(secondsUntil / 60)
      const totalHours = Math.floor(totalMinutes / 60)
      const days = Math.floor(totalHours / 24)
      const hours = totalHours % 24
      const minutes = totalMinutes % 60
      if (days > 0) return `${days}d ${hours}h`
      if (totalHours > 0) return `${totalHours}h ${minutes}m`
      if (totalMinutes > 0) return `${totalMinutes}m`
      return "<1m"
    },
    dollars: (cents) => Math.round((cents / 100) * 100) / 100,
    date: (unixMs) => {
      const d = new Date(Number(unixMs))
      const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
      return months[d.getMonth()] + " " + String(d.getDate())
    },
  },
  base64: { decode: b64decode },
  jwt: {
    decodePayload: (token) => {
      try {
        const parts = token.split(".")
        if (parts.length !== 3) return null
        const decoded = b64decode(parts[1])
        return JSON.parse(decoded)
      } catch (e) {
        return null
      }
    },
  },
})


describe("cursor plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no token", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws on sqlite errors when reading token", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    expect(ctx.host.log.warn).toHaveBeenCalled()
  })

  it("throws on disabled usage", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ enabled: false }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage tracking disabled")
  })

  it("throws on missing plan usage data", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ enabled: true }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage tracking disabled")
  })

  it("renders usage + plan info", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400, bonusSpend: 100 },
            spendLimitUsage: { individualLimit: 5000, individualRemaining: 1000 },
            billingCycleEnd: Date.now(),
          }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ planInfo: { planName: "pro plan" } }),
      }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })

  it("omits plan badge for blank plan names", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
          }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ planInfo: { planName: "   " } }),
      }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeFalsy()
  })

  it("uses pooled spend limits when individual values missing", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
            spendLimitUsage: { pooledLimit: 2000, pooledRemaining: 500 },
          }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ planInfo: { planName: "pro plan" } }),
      }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "On-demand")).toBeTruthy()
  })

  it("throws on token expired", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("throws on http errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on usage request errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed")
  })

  it("throws on parse errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: "not-json",
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("handles plan fetch failure gracefully", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 0, limit: 100 },
          }),
        }
      }
      // Plan fetch fails
      throw new Error("plan fail")
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })
})
