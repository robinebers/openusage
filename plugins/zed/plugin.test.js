import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const mockEnvCredentials = (ctx, userId = "42", accessToken = "env-token") => {
  ctx.host.env.get.mockImplementation((name) => {
    if (name === "ZED_USER_ID") return userId
    if (name === "ZED_ACCESS_TOKEN") return accessToken
    return null
  })
}

const FRONTEND_USAGE = {
  plan: "zed_pro",
  is_account_too_young: false,
  current_usage: {
    token_spend: {
      spend_in_cents: 125,
      limit_in_cents: 500,
      updated_at: "2026-06-01T12:00:00Z",
    },
    edit_predictions: {
      used: 120,
      limit: 2000,
      remaining: 1880,
    },
  },
  portal_url: "https://dashboard.zed.dev/account",
}

const TOKENS_USAGE = {
  usage_by_model: {},
  total_usage: [
    {
      date: "2026-05-31",
      spend_in_cents: 0,
      cost_in_cents: 0,
      tokens: { total: 0 },
    },
    {
      date: "2026-06-01",
      spend_in_cents: 250,
      cost_in_cents: 250,
      tokens: { total: 1250 },
    },
  ],
  usage_cache_updated_at: "2026-06-01T12:00:00Z",
}

const CLIENT_USER = {
  default_organization_id: "test-organization",
  user: {
    id: 42,
    github_login: "zed-user",
  },
  feature_flags: [],
  plan: {
    plan_v3: "zed_pro",
    subscription_period: {
      started_at: "2026-06-01T00:00:00Z",
      ended_at: "2026-07-01T00:00:00Z",
    },
    usage: {
      edit_predictions: {
        used: 400,
        limit: { limited: 1000 },
      },
    },
    is_account_too_young: false,
    has_overdue_invoices: false,
  },
}

const mockFrontendHttp = (ctx, usage = FRONTEND_USAGE, tokens = TOKENS_USAGE) => {
  ctx.host.http.request.mockImplementation((opts) => {
    if (opts.url.endsWith("/client/users/me")) {
      return { status: 200, bodyText: JSON.stringify(CLIENT_USER) }
    }
    if (opts.url.endsWith("/frontend/billing/usage")) {
      return { status: 200, bodyText: JSON.stringify(usage) }
    }
    if (opts.url.endsWith("/frontend/billing/usage/tokens")) {
      return { status: 200, bodyText: JSON.stringify(tokens) }
    }
    throw new Error("unexpected URL " + opts.url)
  })
}

describe("zed plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no credentials are available", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("Zed login required")
  })

  it("uses env credentials and renders dashboard usage", async () => {
    const ctx = makeCtx()
    mockEnvCredentials(ctx, "42", "env-token")
    mockFrontendHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Zed Pro")
    expect(result.lines.find((line) => line.label === "Token Spend")).toMatchObject({
      type: "progress",
      used: 1.25,
      limit: 5,
      format: { kind: "dollars" },
    })
    expect(result.lines.find((line) => line.label === "Edit Predictions")).toMatchObject({
      type: "progress",
      used: 120,
      limit: 2000,
      format: { kind: "count", suffix: "/ 2000" },
    })
    expect(result.links).toEqual([
      { label: "AI Usage", url: "https://dashboard.zed.dev/test-organization/billing/usage" },
    ])
    expect(ctx.host.http.request.mock.calls[0][0].headers.Authorization).toBe("42 env-token")
  })

  it("uses Zed keychain credentials when env credentials are missing", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readInternetPassword.mockReturnValue({
      account: "8675309",
      password: "keychain-token",
    })
    mockFrontendHttp(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.keychain.readInternetPassword).toHaveBeenCalledWith("https://zed.dev")
    expect(ctx.host.http.request.mock.calls[0][0].headers.Authorization).toBe("8675309 keychain-token")
  })

  it("falls back to the client user endpoint when dashboard usage is unavailable", async () => {
    const ctx = makeCtx()
    mockEnvCredentials(ctx)
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.endsWith("/frontend/billing/usage")) {
        return { status: 401, bodyText: "" }
      }
      if (opts.url.endsWith("/client/users/me")) {
        return { status: 200, bodyText: JSON.stringify(CLIENT_USER) }
      }
      throw new Error("unexpected URL " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Zed Pro")
    expect(result.lines.find((line) => line.label === "Edit Predictions")).toMatchObject({
      type: "progress",
      used: 400,
      limit: 1000,
    })
  })

  it("renders token spend as text when no spend limit is set", async () => {
    const ctx = makeCtx()
    mockEnvCredentials(ctx)
    mockFrontendHttp(ctx, {
      ...FRONTEND_USAGE,
      current_usage: {
        ...FRONTEND_USAGE.current_usage,
        token_spend: {
          spend_in_cents: 125,
          limit_in_cents: null,
          updated_at: "2026-06-01T12:00:00Z",
        },
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Token Spend")).toMatchObject({
      type: "text",
      value: "$1.25",
    })
  })

  it("keeps zero-dollar daily spend points in the chart", async () => {
    const ctx = makeCtx()
    mockEnvCredentials(ctx)
    mockFrontendHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const chart = result.lines.find((line) => line.label === "Daily Spend")

    expect(chart.type).toBe("barChart")
    expect(chart.points.map((point) => point.value)).toEqual([0, 2.5])
    expect(chart.points.map((point) => point.valueLabel)).toEqual(["$0.00", "$2.50"])
  })

  it("renders unlimited edit predictions as text", async () => {
    const ctx = makeCtx()
    mockEnvCredentials(ctx)
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.endsWith("/frontend/billing/usage")) {
        return { status: 401, bodyText: "" }
      }
      if (opts.url.endsWith("/client/users/me")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            ...CLIENT_USER,
            plan: {
              ...CLIENT_USER.plan,
              usage: {
                edit_predictions: {
                  used: 25,
                  limit: "unlimited",
                },
              },
            },
          }),
        }
      }
      throw new Error("unexpected URL " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Edit Predictions")).toMatchObject({
      type: "text",
      value: "25 used",
    })
  })

  it("throws when the client user endpoint rejects auth", async () => {
    const ctx = makeCtx()
    mockEnvCredentials(ctx)
    ctx.host.http.request.mockImplementation(() => ({ status: 401, bodyText: "" }))

    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("Zed session expired")
  })
})
