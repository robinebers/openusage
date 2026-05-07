import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const KEYCHAIN_SERVICE = "OpenUsage Fireworks AI API Key"
const BILLING_CSV = `usage_type,model_name,prompt_tokens,completion_tokens,start_time,end_time
TEXT_COMPLETION_INFERENCE_USAGE,accounts/fireworks/models/kimi-k2p5,70000000,33890000,2026-01-03T00:00:00Z,2026-02-02T00:00:00Z`

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const ACCOUNTS = {
  accounts: [
    {
      name: "accounts/acct_primary",
      displayName: "Primary",
      state: "READY",
      suspendState: "UNSUSPENDED",
    },
  ],
}

const QUOTAS = {
  quotas: [
    {
      name: "accounts/acct_primary/quotas/monthly-spend-usd",
      value: 50,
      maxValue: 500,
      usage: 12.34,
      updateTime: "2026-02-01T12:00:00.000Z",
    },
    {
      name: "accounts/acct_primary/quotas/serverless-inference-prompt-tokens-per-second",
      value: 2000,
      usage: 350,
      updateTime: "2026-02-01T12:00:00.000Z",
    },
    {
      name: "accounts/acct_primary/quotas/serverless-inference-generated-tokens-per-second",
      value: 400,
      usage: 80,
      updateTime: "2026-02-01T12:00:00.000Z",
    },
    {
      name: "accounts/acct_primary/quotas/serverless-inference-prompt-tokens",
      usage: 70000000,
      updateTime: "2026-02-01T12:00:00.000Z",
    },
    {
      name: "accounts/acct_primary/quotas/serverless-inference-output-tokens",
      usage: 33890000,
      updateTime: "2026-02-01T12:00:00.000Z",
    },
  ],
}

const mockApi = (ctx, accounts = ACCOUNTS, quotas = QUOTAS) => {
  ctx.host.http.request.mockImplementation((opts) => {
    if (String(opts.url).includes("/accounts?")) return { status: 200, bodyText: JSON.stringify(accounts) }
    return { status: 200, bodyText: JSON.stringify(quotas) }
  })
}

describe("fireworks-ai plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no keychain item or env var is configured", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No Fireworks API key found")
  })

  it("prefers current-user keychain over env", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    ctx.host.env.get.mockImplementation((name) => (name === "FIREWORKS_API_KEY" ? "fw-env-key" : null))
    mockApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Tier 2")
    expect(ctx.host.keychain.readGenericPasswordForCurrentUser).toHaveBeenCalledWith(KEYCHAIN_SERVICE)
    expect(ctx.host.http.request.mock.calls[0][0].headers.Authorization).toBe("Bearer fw-current-user-key")
  })

  it("falls back to FIREWORKS_API_KEY when keychain is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockImplementation(() => {
      throw new Error("keychain item not found")
    })
    ctx.host.keychain.readGenericPassword.mockImplementation(() => {
      throw new Error("keychain item not found")
    })
    ctx.host.env.get.mockImplementation((name) => (name === "FIREWORKS_API_KEY" ? "fw-env-key" : null))
    mockApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.http.request.mock.calls[0][0].headers.Authorization).toBe("Bearer fw-env-key")
  })

  it("renders serverless usage first, then throughput, spend, and budget from quotas", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    ctx.host.fireworks.exportBillingMetrics.mockReturnValue({ status: "ok", csv: BILLING_CSV })
    mockApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Tier 2")
    expect(result.lines[0]).toMatchObject({
      type: "text",
      label: "Serverless usage",
      value: "103.89M tokens",
      subtitle: "Last 30 days",
    })
    expect(result.lines.find((line) => line.label === "Prompt tokens")).toMatchObject({
      type: "text",
      value: "70M tokens",
      subtitle: "Last 30 days",
    })
    expect(result.lines.find((line) => line.label === "Generated tokens")).toMatchObject({
      type: "text",
      value: "33.89M tokens",
      subtitle: "Last 30 days",
    })
    expect(result.lines.find((line) => line.label === "Month spend")).toMatchObject({
      type: "text",
      value: "$12.34",
      subtitle: "This month against budget $50",
    })
    expect(result.lines.find((line) => line.label === "Budget")).toMatchObject({
      type: "text",
      value: "$50",
      subtitle: "Tier cap $500",
    })
  })

  it("uses date-only billing windows for the official export helper", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    ctx.host.fireworks.exportBillingMetrics.mockReturnValue({ status: "empty" })
    mockApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.fireworks.exportBillingMetrics).toHaveBeenCalledWith({
      apiKey: "fw-current-user-key",
      accountId: "acct_primary",
      startTime: "2026-01-04",
      endTime: "2026-02-03",
    })
  })

  it("uses the stripped account id when the account name is a resource path", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    mockApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const quotaCall = ctx.host.http.request.mock.calls[1][0]
    expect(quotaCall.url).toContain("/accounts/acct_primary/quotas?pageSize=200")
  })

  it("shows Budget not set when the account has a tier cap but no configured spend limit", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    mockApi(ctx, ACCOUNTS, {
      quotas: [
        {
          name: "accounts/acct_primary/quotas/monthly-spend-usd",
          value: 0,
          maxValue: 50,
          usage: 0,
          updateTime: "2026-02-01T12:00:00.000Z",
        },
      ],
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Tier 1")
    expect(result.lines.find((line) => line.label === "Budget")).toMatchObject({
      type: "text",
      value: "Not set",
      subtitle: "Tier cap $50",
    })
  })

  it("uses aggregate token quota directly when the API returns a single total-tokens line", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    ctx.host.fireworks.exportBillingMetrics.mockReturnValue({ status: "unavailable" })
    mockApi(ctx, ACCOUNTS, {
      quotas: [
        {
          name: "accounts/acct_primary/quotas/serverless-inference-total-tokens",
          currentUsage: 1250000,
          updateTime: "2026-02-01T12:00:00.000Z",
        },
      ],
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Serverless usage")).toMatchObject({
      type: "text",
      value: "1.25M tokens",
    })
  })

  it("falls back to spend and budget when billing export is unavailable and token quotas are absent", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    ctx.host.fireworks.exportBillingMetrics.mockReturnValue({ status: "no_runner" })
    mockApi(ctx, ACCOUNTS, {
      quotas: [
        {
          name: "accounts/acct_primary/quotas/monthly-spend-usd",
          value: 30,
          maxValue: 50,
          usage: 7,
          updateTime: "2026-02-01T12:00:00.000Z",
        },
      ],
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Serverless usage")).toMatchObject({
      type: "text",
      value: "Unavailable",
      subtitle: "Install firectl for official billing export",
    })
    expect(result.lines.map((line) => line.label)).toEqual(["Serverless usage", "Month spend", "Budget"])
  })

  it("shows account status when the selected account is suspended", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    mockApi(
      ctx,
      {
        accounts: [
          {
            name: "accounts/acct_primary",
            state: "READY",
            suspendState: "SUSPENDED",
          },
        ],
      },
      { quotas: [] }
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Status")).toMatchObject({
      type: "badge",
      text: "SUSPENDED",
    })
  })

  it("throws an invalid-key error on auth failures", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue("fw-current-user-key")
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("API key invalid. Check your Fireworks AI API key.")
  })
})
