import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const FULL_RESPONSE = {
  snapshot_at: "2026-04-16T18:30:00Z",
  balance: {
    credits_remaining_usd: 32.6774,
    total_credits_usd: 52.34,
    credits_used_usd: 19.6626,
    accounting_method: "energy",
  },
  usage: {
    lifetime: { cost_usd: 243.9145, requests: 37801, tokens: 1235477176, energy_kwh: 15.6009 },
    current_month: { cost_usd: 160.1463, requests: 23902, tokens: 1116658995, energy_kwh: 9.7278 },
  },
  limits: { overage_limit_usd: null, rate_limit_tier: "standard" },
  subscription: {
    plan: "standard",
    status: "active",
    billing_interval: "month",
    current_period_start: "2026-04-11T05:05:25Z",
    current_period_end: "2026-05-11T05:05:25Z",
    auto_renew: true,
    kwh_included: 20.0,
    kwh_used: 13.9023,
    kwh_remaining: 6.0977,
    in_overage: false,
  },
  key: { name: "my-production-key", allowance: null },
}

describe("neuralwatt plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when API key is missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Neuralwatt API key missing")
  })

  it("renders subscription + balance + method from full response", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify(FULL_RESPONSE),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Standard")
    expect(result.lines).toHaveLength(3)

    const sub = result.lines.find((l) => l.label === "Subscription")
    expect(sub).toBeTruthy()
    expect(sub.used).toBeCloseTo(13.9023, 4)
    expect(sub.limit).toBeCloseTo(20, 4)
    expect(sub.format).toEqual({ kind: "count", suffix: "kWh" })

    const bal = result.lines.find((l) => l.label === "Balance")
    expect(bal).toBeTruthy()
    expect(bal.used).toBe(19.66)
    expect(bal.limit).toBe(52.34)
    expect(bal.format).toEqual({ kind: "dollars" })
    expect(bal.resetsAt).toBeUndefined()
    expect(bal.periodDurationMs).toBeUndefined()

    const method = result.lines.find((l) => l.label === "Method")
    expect(method).toBeTruthy()
    expect(method.text).toBe("Energy")

    // Line order must match manifest: Subscription, Balance, Method
    expect(result.lines.map((l) => l.label)).toEqual(["Subscription", "Balance", "Method"])
  })

  it("includes resetsAt and periodDurationMs from subscription period", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify(FULL_RESPONSE),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const sub = result.lines.find((l) => l.label === "Subscription")
    expect(sub.resetsAt).toBeTruthy()
    expect(sub.periodDurationMs).toBeTruthy()
  })

  it("hides subscription line when subscription is null", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        balance: { credits_remaining_usd: 10, total_credits_usd: 20, credits_used_usd: 10, accounting_method: "token" },
        subscription: null,
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Subscription")).toBeUndefined()
    const bal = result.lines.find((l) => l.label === "Balance")
    expect(bal).toBeTruthy()
  })

  it("hides balance line when total credits is 0", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        balance: { credits_remaining_usd: 0, total_credits_usd: 0, credits_used_usd: 0, accounting_method: "energy" },
        subscription: FULL_RESPONSE.subscription,
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Balance")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Subscription")).toBeTruthy()
  })

  it("hides method badge when accounting_method is missing", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        balance: { credits_remaining_usd: 10, total_credits_usd: 20, credits_used_usd: 10 },
        subscription: FULL_RESPONSE.subscription,
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Method")).toBeUndefined()
  })

  it("returns badge when no data at all", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ subscription: null, balance: null }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines).toEqual([{ type: "badge", label: "Status", text: "No usage data", color: "#a3a3a3" }])
    expect(result.plan).toBeNull()
  })

  it("throws on 401", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-bad-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Invalid API key")
  })

  it("throws on non-2xx", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on invalid JSON", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "not-json" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Response invalid")
  })

  it("throws on network error", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("network down")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Check your connection")
  })

  it("capitalizes plan name", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    const resp = JSON.parse(JSON.stringify(FULL_RESPONSE))
    resp.subscription.plan = "premium"

    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify(resp),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Premium")
  })

  it("capitalizes accounting method", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-test-key"
      return null
    })
    const resp = JSON.parse(JSON.stringify(FULL_RESPONSE))
    resp.balance.accounting_method = "token"

    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify(resp),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Method").text).toBe("Token")
  })

  it("sends correct authorization header", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "NEURALWATT_API_KEY") return "sk-my-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify(FULL_RESPONSE),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.headers.Authorization).toBe("Bearer sk-my-key")
    expect(call.url).toBe("https://api.neuralwatt.com/v1/quota")
    expect(call.method).toBe("GET")
  })
})
