import { beforeEach, describe, expect, it } from "vitest"
import { makeCtx } from "../test-helpers.js"

const AUTH_PATH = "~/.grok/auth.json"
const BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing"
const SETTINGS_URL = "https://cli-chat-proxy.grok.com/v1/settings"

const loadPlugin = async () => {
  await import("./plugin.js?test=" + Math.random())
  return globalThis.__openusage_plugin
}

function writeAuth(ctx, entry) {
  const auth = {}
  auth["https://auth.x.ai::client"] = entry || {
    key: "test-token",
    email: "user@example.com",
    expires_at: "2026-06-01T00:00:00Z",
  }
  ctx.host.fs.writeText(AUTH_PATH, JSON.stringify(auth))
}

function billingData(overrides) {
  const config = Object.assign({
    monthlyLimit: { val: 60000 },
    used: { val: 4277 },
    onDemandCap: { val: 0 },
    billingPeriodStart: "2026-05-01T00:00:00+00:00",
    billingPeriodEnd: "2026-06-01T00:00:00+00:00",
    history: [
      {
        billingCycle: { year: 2026, month: 4 },
        includedUsed: { val: 1234 },
        onDemandUsed: { val: 200 },
        totalUsed: { val: 1434 },
      },
      {
        billingCycle: { year: 2026, month: 3 },
        includedUsed: { val: 0 },
        onDemandUsed: { val: 0 },
        totalUsed: { val: 0 },
      },
    ],
  }, overrides || {})
  return { config }
}

function mockGrokApi(ctx, data, settings) {
  ctx.host.http.request.mockImplementation((req) => {
    if (req.url === BILLING_URL) {
      return {
        status: 200,
        bodyText: JSON.stringify(data || billingData()),
      }
    }
    if (req.url === SETTINGS_URL) {
      return settings || {
        status: 200,
        bodyText: JSON.stringify({ subscription_tier_display: "SuperGrok Heavy" }),
      }
    }
    return { status: 404, bodyText: "" }
  })
}

describe("grok plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
  })

  it("throws when auth file is missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok not logged in. Run `grok login`.")
  })

  it("throws when auth file has no usable token", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(AUTH_PATH, JSON.stringify({ account: { email: "user@example.com" } }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok auth invalid. Run `grok login` again.")
  })

  it("throws when the only token is expired", async () => {
    const ctx = makeCtx()
    writeAuth(ctx, {
      key: "expired-token",
      email: "user@example.com",
      expires_at: "2026-01-01T00:00:00Z",
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok auth expired. Run `grok login` again.")
  })

  it("uses the first non-expired token", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(AUTH_PATH, JSON.stringify({
      expired: {
        key: "expired-token",
        expires_at: "2026-01-01T00:00:00Z",
      },
      active: {
        key: "active-token",
        email: "active@example.com",
        expires_at: "2026-06-01T00:00:00Z",
      },
    }))
    mockGrokApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("SuperGrok Heavy")
    expect(ctx.host.http.request.mock.calls[0][0].headers.Authorization).toBe("Bearer active-token")
  })

  it("requests the CLI billing endpoint with Grok CLI headers", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.method).toBe("GET")
    expect(call.url).toBe(BILLING_URL)
    expect(call.headers.Authorization).toBe("Bearer test-token")
    expect(call.headers["X-XAI-Token-Auth"]).toBe("xai-grok-cli")
    expect(call.headers.Accept).toBe("application/json")
  })

  it("renders credits used as percent progress", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Credits used")

    expect(line.type).toBe("progress")
    expect(line.used).toBeCloseTo(7.128, 3)
    expect(line.limit).toBe(100)
    expect(line.format).toEqual({ kind: "percent" })
    expect(line.resetsAt).toBe("2026-06-01T00:00:00.000Z")
  })

  it("does not render duplicate reset or billing detail rows", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Resets")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Current period")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Billing cycle")).toBeUndefined()
  })

  it("renders pay as you go disabled when cap is zero", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx, billingData({ onDemandCap: { val: 0 } }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Pay as you go")

    expect(line.type).toBe("badge")
    expect(line.text).toBe("Disabled")
    expect(line.color).toBe("#a3a3a3")
  })

  it("renders pay as you go cap when enabled", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx, billingData({ onDemandCap: { val: "2500" } }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Pay as you go")

    expect(line.text).toBe("2500 cap")
    expect(line.color).toBe("#22c55e")
  })

  it("parses billing values provided as strings", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx, billingData({
      monthlyLimit: { val: "10000" },
      used: { val: "2500" },
      onDemandCap: { val: "0" },
    }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Credits used").used).toBe(25)
    expect(result.lines.find((l) => l.label === "Current period")).toBeUndefined()
  })

  it("reads the plan name from settings instead of auth email", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx, billingData(), {
      status: 200,
      bodyText: JSON.stringify({ subscription_tier_display: "SuperGrok Heavy" }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const settingsCall = ctx.host.http.request.mock.calls.find((call) => call[0].url === SETTINGS_URL)[0]
    expect(settingsCall.headers.Authorization).toBe("Bearer test-token")
    expect(settingsCall.headers["X-XAI-Token-Auth"]).toBe("xai-grok-cli")
    expect(result.plan).toBe("SuperGrok Heavy")
  })

  it("omits the plan label when settings does not include a plan", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx, billingData(), {
      status: 200,
      bodyText: JSON.stringify({ release_channel: "stable" }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe(null)
  })

  it("throws when billing request returns auth error", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok auth expired. Run `grok login` again.")
  })

  it("throws on billing HTTP error", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok billing request failed (HTTP 500). Try again later.")
  })

  it("throws on billing network error", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("offline")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok billing request failed. Check your connection.")
  })

  it("throws on invalid billing JSON", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "not-json" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok billing response changed.")
  })

  it("throws on unexpected billing response shape", async () => {
    const ctx = makeCtx()
    writeAuth(ctx)
    mockGrokApi(ctx, { config: { used: { val: 1 } } })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Grok billing response changed.")
  })
})
