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
            label: "Gemini 3.1 Pro (High)",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M37" },
            quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Gemini 3.1 Pro (Low)",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M36" },
            quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Gemini 3 Flash",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M18" },
            quotaInfo: { remainingFraction: 1.0, resetTime: "2026-02-08T09:10:56Z" },
          },
          {
            label: "Claude Sonnet 4.6 (Thinking)",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M35" },
            quotaInfo: { resetTime: "2026-02-26T15:23:41Z" },
          },
          {
            label: "Claude Opus 4.6 (Thinking)",
            modelOrAlias: { model: "MODEL_PLACEHOLDER_M26" },
            quotaInfo: { resetTime: "2026-02-26T15:23:41Z" },
          },
          {
            label: "GPT-OSS 120B (Medium)",
            modelOrAlias: { model: "MODEL_OPENAI_GPT_OSS_120B_MEDIUM" },
            quotaInfo: { resetTime: "2026-02-26T15:23:41Z" },
          },
        ],
      },
    },
  }
  if (overrides) {
    if (overrides.planName !== undefined) base.userStatus.planStatus.planInfo.planName = overrides.planName
    if (overrides.configs !== undefined) base.userStatus.cascadeModelConfigData.clientModelConfigs = overrides.configs
    if (overrides.planStatus !== undefined) base.userStatus.planStatus = overrides.planStatus
    if (overrides.userTier !== undefined) base.userStatus.userTier = overrides.userTier
  }
  return base
}

function setupLsMock(ctx, discovery, responseBody) {
  ctx.host.ls.discover.mockReturnValue(discovery)
  ctx.host.http.request.mockImplementation((opts) => {
    if (String(opts.url).includes("GetUnleashData")) {
      return { status: 200, bodyText: "{}" }
    }
    return { status: 200, bodyText: JSON.stringify(responseBody) }
  })
}

// --- Tests ---

describe("antigravity-ide plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("registers with correct id", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)
    const plugin = await loadPlugin()
    expect(plugin.id).toBe("antigravity-ide")
  })

  it("throws when LS not found", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity IDE and try again.")
  })

  it("throws when no working port found", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery())
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("connection refused")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity IDE and try again.")
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
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity IDE and try again.")
  })

  it("returns models + plan from GetUserStatus", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Gemini Pro", "Gemini Flash", "Claude"])
  })

  it("deduplicates models by normalized label (keeps worst-case fraction)", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const pro = result.lines.find((l) => l.label === "Gemini Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(20) // (1 - 0.8) * 100
  })

  it("orders: Gemini (Pro, Flash), Claude (Opus, Sonnet), then others", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Gemini Pro", "Gemini Flash", "Claude"])
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
    const pro = result.lines.find((l) => l.label === "Gemini Pro")
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

  it("treats models with no quotaInfo as depleted (100% used)", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini 3 Pro (High)", modelOrAlias: { model: "M7" }, quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "Claude Opus 4.6 (Thinking)", modelOrAlias: { model: "M26" } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const claude = result.lines.find((l) => l.label === "Claude")
    expect(claude).toBeTruthy()
    expect(claude.used).toBe(100)
    expect(claude.limit).toBe(100)
    expect(claude.resetsAt).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Gemini Pro")).toBeTruthy()
  })

  it("skips configs with missing or empty labels", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini 3 Pro (High)", modelOrAlias: { model: "M7" }, quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "", modelOrAlias: { model: "M99" }, quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T09:10:56Z" } },
        { modelOrAlias: { model: "M100" }, quotaInfo: { remainingFraction: 0.9, resetTime: "2026-02-08T09:10:56Z" } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Gemini Pro")
  })

  it("includes resetsAt on model lines", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((l) => l.label === "Gemini Pro")
    expect(pro.resetsAt).toBe("2026-02-08T09:10:56Z")
  })

  it("clamps remainingFraction outside 0-1 range", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini Pro (Over)", modelOrAlias: { model: "M1" }, quotaInfo: { remainingFraction: 1.5, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "Gemini Flash (Neg)", modelOrAlias: { model: "M2" }, quotaInfo: { remainingFraction: -0.3, resetTime: "2026-02-08T09:10:56Z" } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const over = result.lines.find((l) => l.label === "Gemini Pro")
    const neg = result.lines.find((l) => l.label === "Gemini Flash")
    expect(over.used).toBe(0) // clamped to 1.0 → 0% used
    expect(neg.used).toBe(100) // clamped to 0.0 → 100% used
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
        if (port === 10002 && scheme === "https") return { status: 200, bodyText: "{}" }
        throw new Error("refused")
      }
      return { status: 200, bodyText: JSON.stringify(makeUserStatusResponse()) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
    expect(probed).toEqual([
      { port: 10001, scheme: "https" },
      { port: 10001, scheme: "http" },
      { port: 10002, scheme: "https" },
    ])
  })

  it("never sends apiKey in LS metadata", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)

    let capturedMetadata = null
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      if (url.includes("GetUserStatus")) {
        const body = JSON.parse(opts.bodyText)
        capturedMetadata = body.metadata
        return { status: 200, bodyText: JSON.stringify(response) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBeGreaterThan(0)
    expect(capturedMetadata).toBeTruthy()
    expect(capturedMetadata.apiKey).toBeUndefined()
    expect(capturedMetadata.ideName).toBe("antigravity-ide")
    expect(capturedMetadata.extensionName).toBe("antigravity-ide")
  })

  it("sends antigravity-ide marker to ls.discover", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)
    const plugin = await loadPlugin()
    try { plugin.probe(ctx) } catch (e) { /* expected */ }
    expect(ctx.host.ls.discover).toHaveBeenCalledWith({
      processName: "language_server_macos",
      markers: ["antigravity-ide"],
      csrfFlag: "--csrf_token",
      portFlag: "--extension_server_port",
    })
  })

  it("prefers userTier.name over planInfo.planName", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({ userTier: { name: "Ultra" } })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Ultra")
  })

  it("filters blacklisted model IDs", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini 3 Pro (High)", modelOrAlias: { model: "MODEL_PLACEHOLDER_M37" }, quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "Blacklisted Model", modelOrAlias: { model: "MODEL_GOOGLE_GEMINI_2_5_PRO" }, quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T09:10:56Z" } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Gemini Pro")
  })
})
