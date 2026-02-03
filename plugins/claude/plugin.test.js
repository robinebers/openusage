import { beforeEach, describe, expect, it, vi } from "vitest"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const makeCtx = () => {
  const files = new Map()
  return {
    host: {
      fs: {
        exists: (path) => files.has(path),
        readText: (path) => files.get(path),
      },
      keychain: {
        readGenericPassword: vi.fn(),
      },
      http: {
        request: vi.fn(),
      },
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
  }
}

describe("claude plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no credentials", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when credentials are unreadable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "{bad json"
    ctx.host.keychain.readGenericPassword.mockReturnValue("{bad}")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("renders usage lines from response", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        seven_day: { utilization: 20, resets_at: "2099-01-01T00:00:00.000Z" },
        extra_usage: { is_enabled: true, used_credits: 500, monthly_limit: 1000 },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()
  })

  it("throws token expired on 401", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("uses keychain credentials", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_sonnet: { utilization: 5, resets_at: "2099-01-01T00:00:00.000Z" },
        extra_usage: { is_enabled: true, used_credits: 250 },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Sonnet")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Extra usage")).toBeTruthy()
  })

  it("uses keychain credentials when value is hex-encoded JSON", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    const json = JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } }, null, 2)
    const hex = Buffer.from(json, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 1, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("throws on http errors and parse failures", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValueOnce({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")

    ctx.host.http.request.mockReturnValueOnce({ status: 200, bodyText: "not-json" })
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("throws on request errors", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed")
  })

  it("returns status when no usage data", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({}),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("formats reset windows under an hour", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    const now = new Date("2026-02-02T00:00:00.000Z").getTime()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: new Date(now + 30_000).toISOString() },
        seven_day: { utilization: 20, resets_at: new Date(now + 5 * 60_000).toISOString() },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.some((line) => line.subtitle && line.subtitle.includes("<1m"))).toBe(true)
    expect(result.lines.some((line) => line.subtitle && line.subtitle.includes("5m"))).toBe(true)
    nowSpy.mockRestore()
  })

  it("handles invalid reset timestamps", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_opus: { utilization: 33, resets_at: "not-a-date" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Opus")).toBeTruthy()
  })
})
