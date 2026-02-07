import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

// --- Fixtures ---

function makeDiscovery(overrides) {
  return Object.assign(
    { pid: 12345, csrf: "test-csrf-token", ports: [42001, 42002], extensionPort: null },
    overrides
  )
}

function makeUserStatusResponse(overrides) {
  var base = {
    userStatus: {
      planStatus: {
        planInfo: {
          planName: "Pro",
          monthlyPromptCredits: 50000,
          monthlyFlowCredits: 150000,
          monthlyFlexCreditPurchaseAmount: 25000,
        },
        availablePromptCredits: 500,
        availableFlowCredits: 100,
        usedFlexCredits: 5000,
      },
      cascadeModelConfigData: {
        clientModelConfigs: [
          {
            label: "Gemini 3 Pro (High)",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M7" },
            quotaInfo: { remainingFraction: 0.75, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Gemini 3 Pro (Low)",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M6" },
            quotaInfo: { remainingFraction: 0.9, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Gemini 3 Flash",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M8" },
            quotaInfo: { remainingFraction: 1.0, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Claude Sonnet 4.5",
            modelOrAlias: { model: "MODEL_333" },
            quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Claude Opus 4.5 (Thinking)",
            modelOrAlias: { model: "MODEL_1012" },
            quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "GPT-OSS 120B (Medium)",
            modelOrAlias: { model: "MODEL_342" },
            quotaInfo: { remainingFraction: 1.0, resetTime: "2026-02-08T09:10:56Z" },
          },
        ],
      },
    },
  }
  if (overrides) {
    if (overrides.planName !== undefined) base.userStatus.planStatus.planInfo.planName = overrides.planName
    if (overrides.configs !== undefined) base.userStatus.cascadeModelConfigData.clientModelConfigs = overrides.configs
    if (overrides.planStatus !== undefined) base.userStatus.planStatus = overrides.planStatus
  }
  return base
}

function setupHttpMock(ctx, discovery, responseBody) {
  ctx.host.ls.discover.mockReturnValue(discovery)
  ctx.host.http.request.mockImplementation((opts) => {
    if (String(opts.url).includes("GetUnleashData")) {
      return { status: 200, bodyText: "{}" }
    }
    return { status: 200, bodyText: JSON.stringify(responseBody) }
  })
}

// --- Tests ---

describe("antigravity plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when LS not found", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("throws when no working port found", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery())
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("connection refused")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("throws when both GetUserStatus and GetCommandModelConfigs fail", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery())
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 500, bodyText: "" }
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No data from language server.")
  })

  it("returns models + plan from GetUserStatus", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")

    // Model lines exist
    const labels = result.lines.map((l) => l.label)
    expect(labels).toContain("Gemini 3 Pro")
    expect(labels).toContain("Gemini 3 Flash")
    expect(labels).toContain("Claude Sonnet 4.5")
    expect(labels).toContain("Claude Opus 4.5")
    expect(labels).toContain("GPT-OSS 120B")
  })

  it("deduplicates models by normalized label (keeps worst-case fraction)", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    // "Gemini 3 Pro (High)" has 0.75 remaining, "(Low)" has 0.9.
    // Deduplicated to "Gemini 3 Pro" with worst-case 0.75 → used = 25%
    const pro = result.lines.find((l) => l.label === "Gemini 3 Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(25) // (1 - 0.75) * 100
  })

  it("orders: Gemini (Pro, Flash), Claude (Opus, Sonnet), then others", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)

    expect(labels).toEqual([
      "Gemini 3 Pro",
      "Gemini 3 Flash",
      "Claude Opus 4.5",
      "Claude Sonnet 4.5",
      "GPT-OSS 120B",
    ])
  })

  it("falls back to GetCommandModelConfigs when GetUserStatus fails", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery())
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      if (String(opts.url).includes("GetUserStatus")) {
        return { status: 500, bodyText: "" }
      }
      if (String(opts.url).includes("GetCommandModelConfigs")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            clientModelConfigs: [
              {
                label: "Gemini 3 Pro (High)",
                modelOrAlias: { model: "M7" },
                quotaInfo: { remainingFraction: 0.6, resetTime: "2026-02-08T09:10:56Z" },
              },
            ],
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeNull()

    // Model lines present
    const pro = result.lines.find((l) => l.label === "Gemini 3 Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(40) // (1 - 0.6) * 100
  })

  it("uses extension port as fallback when all ports fail probing", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery({ ports: [99999], extensionPort: 42010 }))

    let usedPort = null
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("GetUnleashData") && url.includes("99999")) {
        throw new Error("refused")
      }
      if (url.includes("GetUserStatus")) {
        usedPort = parseInt(url.match(/:(\d+)\//)[1])
        return {
          status: 200,
          bodyText: JSON.stringify(makeUserStatusResponse()),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(usedPort).toBe(42010)
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("skips models with no quotaInfo", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini 3 Pro (High)", modelOrAlias: { model: "M7" }, quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "No Quota Model", modelOrAlias: { model: "M99" } },
      ],
    })
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "No Quota Model")).toBeFalsy()
    expect(result.lines.find((l) => l.label === "Gemini 3 Pro")).toBeTruthy()
  })

  it("includes resetsAt on model lines", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((l) => l.label === "Gemini 3 Pro")
    expect(pro.resetsAt).toBe("2026-02-08T09:10:56Z")
  })

  it("clamps remainingFraction outside 0-1 range", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Over Model", modelOrAlias: { model: "M1" }, quotaInfo: { remainingFraction: 1.5, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "Negative Model", modelOrAlias: { model: "M2" }, quotaInfo: { remainingFraction: -0.3, resetTime: "2026-02-08T09:10:56Z" } },
      ],
    })
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const over = result.lines.find((l) => l.label === "Over Model")
    const neg = result.lines.find((l) => l.label === "Negative Model")
    expect(over.used).toBe(0) // clamped to 1.0 → 0% used
    expect(neg.used).toBe(100) // clamped to 0.0 → 100% used
  })

  it("handles missing resetTime gracefully", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "No Reset", modelOrAlias: { model: "M1" }, quotaInfo: { remainingFraction: 0.5 } },
      ],
    })
    setupHttpMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "No Reset")
    expect(line).toBeTruthy()
    expect(line.used).toBe(50)
    expect(line.resetsAt).toBeUndefined()
  })

  it("probes ports with HTTPS first, then HTTP, picks first success", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery({ ports: [10001, 10002] }))

    const probed = []
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("GetUnleashData")) {
        const port = parseInt(url.match(/:(\d+)\//)[1])
        const scheme = url.startsWith("https") ? "https" : "http"
        probed.push({ port, scheme })
        // Port 10001 refuses both, port 10002 accepts HTTPS
        if (port === 10002 && scheme === "https") return { status: 200, bodyText: "{}" }
        throw new Error("refused")
      }
      return { status: 200, bodyText: JSON.stringify(makeUserStatusResponse()) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
    // Should try HTTPS then HTTP on 10001 (both fail), then HTTPS on 10002 (success)
    expect(probed).toEqual([
      { port: 10001, scheme: "https" },
      { port: 10001, scheme: "http" },
      { port: 10002, scheme: "https" },
    ])
  })
})
