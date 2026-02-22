import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const mockEnvWithKey = (ctx, key, varName = "ZAI_API_KEY") => {
  ctx.host.env.get.mockImplementation((name) => (name === varName ? key : null))
}

const QUOTA_RESPONSE = {
  code: 200,
  data: {
    limits: [
      {
        type: "TOKENS_LIMIT",
        usage: 800000000,
        currentValue: 1900000,
        percentage: 10,
        nextResetTime: 1738368000000,
        unit: 3,
        number: 5,
      },
      {
        type: "TIME_LIMIT",
        usage: 4000,
        currentValue: 1095,
        percentage: 27,
        remaining: 2905,
        usageDetails: [
          { modelCode: "search-prime", usage: 951 },
          { modelCode: "web-reader", usage: 211 },
          { modelCode: "zread", usage: 0 },
        ],
        unit: 5,
        number: 1,
      },
    ],
  },
}

const QUOTA_RESPONSE_NO_TIME_LIMIT = {
  code: 200,
  data: {
    limits: [
      {
        type: "TOKENS_LIMIT",
        usage: 800000000,
        currentValue: 1900000,
        percentage: 10,
        nextResetTime: 1738368000000,
        unit: 3,
        number: 5,
      },
    ],
  },
}

const SUBSCRIPTION_RESPONSE = {
  data: [{ productName: "GLM Coding Max", nextRenewTime: "2026-03-12" }],
}

const mockHttp = (ctx) => {
  ctx.host.http.request.mockImplementation((opts) => {
    if (opts.url.includes("subscription")) {
      return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
    }
    return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
  })
}

describe("zai plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no env vars set", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No ZAI_API_KEY found. Set up environment variable first.")
  })

  it("uses ZAI_API_KEY when set", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("falls back to GLM_API_KEY when ZAI_API_KEY is missing", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "glm-key", "GLM_API_KEY")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("prefers ZAI_API_KEY over GLM_API_KEY", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "ZAI_API_KEY") return "zai-key"
      if (name === "GLM_API_KEY") return "glm-key"
      return null
    })
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
    const authHeader = ctx.host.http.request.mock.calls[0][0].headers.Authorization
    expect(authHeader).toBe("Bearer zai-key")
  })

  it("renders session usage as percent from quota response", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Session")
    expect(line).toBeTruthy()
    expect(line.type).toBe("progress")
    expect(line.used).toBe(10)
    expect(line.limit).toBe(100)
    expect(line.format).toEqual({ kind: "percent" })
    expect(line.periodDurationMs).toBe(5 * 60 * 60 * 1000)
  })

  it("extracts plan name from subscription response", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("GLM Coding Max")
  })

  it("handles subscription fetch failure gracefully", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 500, bodyText: "" }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("throws on 401 from quota endpoint", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 401, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("API key invalid")
  })

  it("throws on HTTP 500 from quota endpoint", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on network exception", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      throw new Error("ECONNREFUSED")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("throws on invalid JSON from quota endpoint", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: "not-json" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("shows badge when limits array is empty", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify({ data: { limits: [] } }) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("passes resetsAt from nextResetTime (epoch ms to ISO)", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Session")
    expect(line.resetsAt).toBe(new Date(1738368000000).toISOString())
  })

  it("renders Web Searches line with count format and 1st-of-month reset", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    mockHttp(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Web Searches")
    expect(line).toBeTruthy()
    expect(line.type).toBe("progress")
    expect(line.used).toBe(1095)
    expect(line.limit).toBe(4000)
    expect(line.format).toEqual({ kind: "count", suffix: "/ 4000" })
    expect(line.periodDurationMs).toBe(30 * 24 * 60 * 60 * 1000)
    const now = new Date()
    const expected1st = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1))
    expect(line.resetsAt).toBe(expected1st.toISOString())
  })

  it("skips Web Searches when TIME_LIMIT is absent", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE_NO_TIME_LIMIT) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Web Searches")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("Web Searches still has resetsAt (1st of month) even when subscription fails", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 500, bodyText: "" }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Web Searches")
    expect(line).toBeTruthy()
    const now = new Date()
    const expected1st = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1))
    expect(line.resetsAt).toBe(expected1st.toISOString())
  })

  it("handles missing nextResetTime gracefully", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    const quotaNoReset = {
      data: {
        limits: [
          { type: "TOKENS_LIMIT", percentage: 10 },
        ],
      },
    }
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify(quotaNoReset) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Session")
    expect(line).toBeTruthy()
    expect(line.resetsAt).toBeUndefined()
  })

  it("handles invalid subscription JSON without failing quota rendering", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: "not-json" }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("handles subscription payload with empty list", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify({ data: [] }) }
      }
      return { status: 200, bodyText: JSON.stringify(QUOTA_RESPONSE) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("supports quota payloads where limits are top-level and optional fields are non-numeric", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify([
          { type: "TOKENS_LIMIT", percentage: "10", nextResetTime: 1738368000000 },
          { type: "TIME_LIMIT", currentValue: "1095", usage: "4000" },
        ]),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((l) => l.label === "Session")
    const web = result.lines.find((l) => l.label === "Web Searches")
    expect(session.used).toBe(0)
    expect(web.used).toBe(0)
    expect(web.limit).toBe(0)
  })

  it("shows no-usage badge when token limit entry is missing", async () => {
    const ctx = makeCtx()
    mockEnvWithKey(ctx, "test-key")
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("subscription")) {
        return { status: 200, bodyText: JSON.stringify(SUBSCRIPTION_RESPONSE) }
      }
      return { status: 200, bodyText: JSON.stringify({ data: { limits: [{ type: "TIME_LIMIT", usage: 10 }] } }) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0].text).toBe("No usage data")
  })
})
