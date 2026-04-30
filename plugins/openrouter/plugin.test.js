import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const mockEnvWithKey = (ctx, key = "sk-or-test") => {
  ctx.host.env.get.mockImplementation((name) => (name === "OPENROUTER_API_KEY" ? key : null))
}

const KEY_RESPONSE = {
  data: {
    label: "OpenClaw",
    limit: 25,
    usage: 4.5,
    usage_daily: 0.5,
    usage_weekly: 1.25,
    usage_monthly: 2.75,
    limit_remaining: 20.5,
    is_free_tier: false,
  },
}

const CREDIT_CAPABLE_KEY_RESPONSE = {
  data: {
    label: "sk-or-v1-abcd...wxyz",
    is_management_key: false,
    is_provisioning_key: false,
    limit: null,
    limit_reset: null,
    limit_remaining: null,
    include_byok_in_limit: false,
    usage: 0,
    usage_daily: 0,
    usage_weekly: 0,
    usage_monthly: 0,
    byok_usage: 0,
    byok_usage_daily: 0,
    byok_usage_weekly: 0,
    byok_usage_monthly: 0,
    is_free_tier: false,
  },
}

const CREDITS_RESPONSE = {
  data: {
    total_credits: 110,
    total_usage: 12.5,
  },
}

const mockHttpJson = (ctx, payload = KEY_RESPONSE, status = 200) => {
  ctx.host.http.request.mockReturnValue({
    status: status,
    bodyText: JSON.stringify(payload),
  })
}

describe("openrouter plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when OPENROUTER_API_KEY is missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No OPENROUTER_API_KEY found. Set up environment variable first.")
  })

  it("requests the current key endpoint with bearer auth", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "sk-or-live")
    mockHttpJson(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.http.request).toHaveBeenCalledWith({
      method: "GET",
      url: "https://openrouter.ai/api/v1/key",
      headers: {
        Authorization: "Bearer sk-or-live",
        Accept: "application/json",
      },
      timeoutMs: 10000,
    })
  })

  it("renders credits, this month, and all time text lines", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    mockHttpJson(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Paid")
    expect(result.lines).toEqual([
      { type: "text", label: "Credits", value: "$20.50 left" },
      { type: "text", label: "This Month", value: "$2.75" },
      { type: "text", label: "All Time", value: "$4.50" },
    ])
  })

  it("uses limit_remaining when usage is unavailable", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    mockHttpJson(ctx, {
      data: {
        label: "Recovered Usage",
        limit: 10,
        usage: null,
        usage_daily: 0,
        usage_weekly: 0,
        usage_monthly: 0,
        limit_remaining: 7.5,
        is_free_tier: false,
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const credits = result.lines.find((line) => line.label === "Credits")

    expect(credits).toEqual({ type: "text", label: "Credits", value: "$7.50 left" })
  })

  it("shows no key limit when no spending limit is configured", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    mockHttpJson(ctx, {
      data: {
        label: "Unlimited",
        limit: null,
        usage: 4.5,
        usage_daily: 0.5,
        usage_weekly: 1.25,
        usage_monthly: 2.75,
        limit_remaining: null,
        is_free_tier: false,
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0]).toEqual({
      type: "text",
      label: "Credits",
      value: "No key limit",
    })
    expect(result.lines[1]).toEqual({ type: "text", label: "This Month", value: "$2.75" })
  })

  it("uses /credits when the endpoint is available", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url === "https://openrouter.ai/api/v1/key") {
        return { status: 200, bodyText: JSON.stringify(CREDIT_CAPABLE_KEY_RESPONSE) }
      }
      if (opts.url === "https://openrouter.ai/api/v1/credits") {
        return { status: 200, bodyText: JSON.stringify(CREDITS_RESPONSE) }
      }
      throw new Error("unexpected url " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0]).toEqual({
      type: "text",
      label: "Credits",
      value: "$97.50 left",
    })
    expect(result.lines.find((line) => line.label === "All Time")).toEqual({
      type: "text",
      label: "All Time",
      value: "$12.50",
    })
  })

  it("prefers the Free plan label for free tier keys", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    mockHttpJson(ctx, {
      data: {
        label: "Personal",
        limit: 5,
        usage: 1,
        usage_daily: 0,
        usage_weekly: 0.25,
        usage_monthly: 0.5,
        limit_remaining: 4,
        is_free_tier: true,
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Free")
  })

  it("keeps zero-usage values instead of dropping them", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    mockHttpJson(ctx, {
      data: {
        label: "Zeroed",
        limit: 10,
        usage: 0,
        usage_daily: 0,
        usage_weekly: 0,
        usage_monthly: 0,
        limit_remaining: 10,
        is_free_tier: false,
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines).toContainEqual({ type: "text", label: "This Month", value: "$0.00" })
    expect(result.lines).toContainEqual({ type: "text", label: "All Time", value: "$0.00" })
  })

  it("throws on auth failures", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("API key invalid. Check your OpenRouter API key.")
  })

  it("throws on non-2xx responses", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed (HTTP 500). Try again later.")
  })

  it("throws on network failures", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("socket hang up")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("throws on invalid JSON", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx)
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "not-json" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid. Try again later.")
  })
})
