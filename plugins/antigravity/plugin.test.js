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
  }
  return base
}

function makeCloudCodeResponse(overrides) {
  return Object.assign(
    {
      models: {
        "gemini-3-pro": {
          displayName: "Gemini 3 Pro",
          model: "gemini-3-pro",
          quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T10:00:00Z" },
        },
        "claude-sonnet-4.5": {
          displayName: "Claude Sonnet 4.5",
          model: "claude-sonnet-4.5",
          quotaInfo: { remainingFraction: 0.6, resetTime: "2026-02-08T10:00:00Z" },
        },
      },
    },
    overrides
  )
}

function makeAuthStatusJson(overrides) {
  return JSON.stringify(
    Object.assign({ apiKey: "test-api-key-123", email: "user@example.com", name: "Test User" }, overrides)
  )
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

function setupSqliteMock(ctx, authJson, protoBase64) {
  ctx.host.sqlite.query.mockImplementation((db, sql) => {
    if (sql.includes("agentManagerInitState") && protoBase64) {
      return JSON.stringify([{ value: protoBase64 }])
    }
    if (sql.includes("antigravityAuthStatus") && authJson) {
      return JSON.stringify([{ value: authJson }])
    }
    return "[]"
  })
}

function makeProtobufBase64(ctx, accessToken, refreshToken, expirySeconds) {
  function encodeVarint(n) {
    var bytes = ""
    while (n > 0x7f) {
      bytes += String.fromCharCode((n & 0x7f) | 0x80)
      n = Math.floor(n / 128)
    }
    bytes += String.fromCharCode(n & 0x7f)
    return bytes
  }
  function encodeField(fieldNum, wireType, data) {
    var tag = encodeVarint(fieldNum * 8 + wireType)
    if (wireType === 2) return tag + encodeVarint(data.length) + data
    if (wireType === 0) return tag + encodeVarint(data)
    return ""
  }
  var inner = ""
  if (accessToken) inner += encodeField(1, 2, accessToken)
  if (refreshToken) inner += encodeField(3, 2, refreshToken)
  if (expirySeconds !== null && expirySeconds !== undefined) {
    var tsMsg = encodeField(1, 0, expirySeconds)
    inner += encodeField(4, 2, tsMsg)
  }
  var outer = encodeField(6, 2, inner)
  return ctx.base64.encode(outer)
}

// --- Tests ---

describe("antigravity plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when LS not found and no DB credentials", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("throws when no working port found and no DB credentials", async () => {
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
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("returns models + plan from GetUserStatus", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")

    // Model lines exist — 3 pool lines
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

    // Both Gemini 3.1 Pro variants have frac=0.8 → used = 20%
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

    // Model lines present
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

  it("dedup picks depleted variant (no quotaInfo) over non-depleted sibling", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini 3 Pro (High)", modelOrAlias: { model: "M7" }, quotaInfo: { remainingFraction: 0.75, resetTime: "2026-02-08T09:10:56Z" } },
        { label: "Gemini 3 Pro (Low)", modelOrAlias: { model: "M8" } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((l) => l.label === "Gemini Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(100)
    expect(pro.resetsAt).toBeUndefined()
  })

  it("returns lines when all models are depleted (no quotaInfo)", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini 3 Pro (High)", modelOrAlias: { model: "M7" } },
        { label: "Claude Opus 4.6 (Thinking)", modelOrAlias: { model: "M26" } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result).toBeTruthy()
    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Gemini Pro", "Claude"])
    expect(result.lines.every((l) => l.used === 100)).toBe(true)
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

  it("handles missing resetTime gracefully", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        { label: "Gemini Pro (No Reset)", modelOrAlias: { model: "M1" }, quotaInfo: { remainingFraction: 0.5 } },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Gemini Pro")
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

  it("includes apiKey in LS metadata when DB has credentials", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson())
    const discovery = makeDiscovery()
    ctx.host.ls.discover.mockReturnValue(discovery)

    let capturedMetadata = null
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      if (url.includes("GetUserStatus")) {
        const body = JSON.parse(opts.bodyText)
        capturedMetadata = body.metadata
        return { status: 200, bodyText: JSON.stringify(makeUserStatusResponse()) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedMetadata).toBeTruthy()
    expect(capturedMetadata.apiKey).toBe("test-api-key-123")
    expect(capturedMetadata.ideName).toBe("antigravity")
  })

  it("works without apiKey when SQLite returns empty", async () => {
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
  })

  it("falls back to Cloud Code API when LS is not available", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("fetchAvailableModels")) {
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeNull()
    const labels = result.lines.map((l) => l.label)
    expect(labels).toContain("Gemini Pro")
    expect(labels).toContain("Claude")
  })

  it("Cloud Code sends correct Authorization header with proto token", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.proto-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedHeaders = null
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("fetchAvailableModels")) {
        capturedHeaders = opts.headers
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedHeaders).toBeTruthy()
    expect(capturedHeaders.Authorization).toBe("Bearer ya29.proto-token")
    expect(capturedHeaders["User-Agent"]).toBe("antigravity")
  })

  it("Cloud Code returns null on 401/403 (invalid token, no refresh)", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.bad-token", null, futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("fetchAvailableModels")) {
        return { status: 401, bodyText: '{"error":"unauthorized"}' }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("Cloud Code tries multiple base URLs", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    const calledUrls = []
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("fetchAvailableModels")) {
        calledUrls.push(url)
        if (url.includes("daily-cloudcode")) {
          throw new Error("network error")
        }
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(calledUrls.length).toBe(2)
    expect(calledUrls[0]).toContain("daily-cloudcode-pa.googleapis.com")
    expect(calledUrls[1]).toContain("cloudcode-pa.googleapis.com")
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("Cloud Code correctly parses model quota response", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            models: {
              "gemini-3-pro-high": {
                displayName: "Gemini 3 Pro (High)",
                quotaInfo: { remainingFraction: 0.7, resetTime: "2026-02-08T12:00:00Z" },
              },
              "gemini-3-pro-low": {
                displayName: "Gemini 3 Pro (Low)",
                quotaInfo: { remainingFraction: 0.9, resetTime: "2026-02-08T12:00:00Z" },
              },
            },
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const pro = result.lines.find((l) => l.label === "Gemini Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(30)
  })

  it("skips Cloud Code when no credentials available", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })

  it("LS takes priority over Cloud Code when both available", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    const calls = ctx.host.http.request.mock.calls.map((c) => String(c[0].url))
    const ccCalls = calls.filter((u) => u.includes("fetchAvailableModels"))
    expect(ccCalls.length).toBe(0)
  })

  it("Cloud Code treats models without quotaInfo as depleted (100% used)", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            models: {
              "valid-model": {
                displayName: "Gemini 3 Pro",
                quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T12:00:00Z" },
              },
              "no-quota": {
                displayName: "Gemini Flash (No Quota)",
              },
            },
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const noQuota = result.lines.find((l) => l.label === "Gemini Flash")
    expect(noQuota).toBeTruthy()
    expect(noQuota.used).toBe(100)
    expect(noQuota.limit).toBe(100)
    expect(noQuota.resetsAt).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Gemini Pro")).toBeTruthy()
  })

  it("decodes protobuf tokens from SQLite", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.test-access", "1//refresh-token", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer ya29.test-access")
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("handles missing protobuf data gracefully (falls back to apiKey)", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson())
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer test-api-key-123")
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("handles corrupt protobuf base64 gracefully (falls back to apiKey)", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson(), "not-valid-protobuf!!!")
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer test-api-key-123")
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("handles protobuf with no refresh_token or expiry", async () => {
    const ctx = makeCtx()
    const protoB64 = makeProtobufBase64(ctx, "ya29.access-only", null, null)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer ya29.access-only")
  })

  it("sends correct form-urlencoded POST to Google OAuth", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.expired", "1//my-refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    let oauthBody = null
    let oauthHeaders = null
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth2.googleapis.com")) {
        oauthBody = opts.bodyText
        oauthHeaders = opts.headers
        return { status: 200, bodyText: JSON.stringify({ access_token: "ya29.refreshed-token" }) }
      }
      if (url.includes("fetchAvailableModels")) {
        if (opts.headers.Authorization === "Bearer ya29.refreshed-token") {
          return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
        }
        return { status: 401, bodyText: '{"error":"unauthorized"}' }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(oauthHeaders["Content-Type"]).toBe("application/x-www-form-urlencoded")
    expect(oauthBody).toContain("client_id=")
    expect(oauthBody).toContain("client_secret=")
    expect(oauthBody).toContain("refresh_token=" + encodeURIComponent("1//my-refresh"))
    expect(oauthBody).toContain("grant_type=refresh_token")
  })

  it("throws when all tokens fail and refresh returns invalid_grant", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.expired", "1//bad-refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth2.googleapis.com")) {
        return { status: 400, bodyText: '{"error":"invalid_grant"}' }
      }
      if (url.includes("fetchAvailableModels")) {
        return { status: 401, bodyText: '{"error":"unauthorized"}' }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("tries proto token first, then apiKey on auth failure", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.proto-first", "1//refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    const capturedTokens = []
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("fetchAvailableModels")) {
        capturedTokens.push(opts.headers.Authorization)
        if (opts.headers.Authorization === "Bearer ya29.proto-first") {
          return { status: 401, bodyText: '{"error":"unauthorized"}' }
        }
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(capturedTokens[0]).toBe("Bearer ya29.proto-first")
    expect(capturedTokens[capturedTokens.length - 1]).toBe("Bearer test-api-key-123")
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("tries both tokens before refreshing", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.both-fail", "1//refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    const capturedTokens = []
    let refreshCalled = false
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth2.googleapis.com")) {
        refreshCalled = true
        return { status: 200, bodyText: JSON.stringify({ access_token: "ya29.refreshed" }) }
      }
      if (url.includes("fetchAvailableModels")) {
        capturedTokens.push(opts.headers.Authorization)
        if (opts.headers.Authorization === "Bearer ya29.refreshed") {
          return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
        }
        return { status: 401, bodyText: '{"error":"unauthorized"}' }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(refreshCalled).toBe(true)
    expect(capturedTokens.filter((t) => t === "Bearer ya29.both-fail").length).toBeGreaterThan(0)
    expect(capturedTokens.filter((t) => t === "Bearer test-api-key-123").length).toBeGreaterThan(0)
    expect(capturedTokens[capturedTokens.length - 1]).toBe("Bearer ya29.refreshed")
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("deduplicates identical tokens", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.same-token", "1//refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson({ apiKey: "ya29.same-token" }), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    const capturedTokens = []
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth2.googleapis.com")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "ya29.refreshed" }) }
      }
      if (url.includes("fetchAvailableModels")) {
        capturedTokens.push(opts.headers.Authorization)
        if (opts.headers.Authorization === "Bearer ya29.same-token") {
          return { status: 401, bodyText: '{"error":"unauthorized"}' }
        }
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const sameTokenCalls = capturedTokens.filter((t) => t === "Bearer ya29.same-token")
    expect(sameTokenCalls.length).toBe(1)
    expect(result.lines.length).toBeGreaterThan(0)
  })

  it("uses apiKey as only token when proto data unavailable", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson())
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer test-api-key-123")
  })

  it("caches refreshed token to pluginDataDir", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.will-fail", "1//refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth2.googleapis.com")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "ya29.refreshed", expires_in: 3599 }) }
      }
      if (url.includes("fetchAvailableModels")) {
        if (opts.headers.Authorization === "Bearer ya29.refreshed") {
          return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
        }
        return { status: 401, bodyText: '{"error":"unauthorized"}' }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const cachePath = ctx.app.pluginDataDir + "/auth.json"
    expect(ctx.host.fs.writeText).toHaveBeenCalledWith(cachePath, expect.any(String))
    const cached = JSON.parse(ctx.host.fs.writeText.mock.calls.find((c) => c[0] === cachePath)[1])
    expect(cached.accessToken).toBe("ya29.refreshed")
    expect(cached.expiresAtMs).toBeGreaterThan(Date.now())
  })

  it("uses cached token before falling back to apiKey", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson())
    ctx.host.ls.discover.mockReturnValue(null)

    const cachePath = ctx.app.pluginDataDir + "/auth.json"
    ctx.host.fs.writeText(cachePath, JSON.stringify({
      accessToken: "ya29.cached-token",
      expiresAtMs: Date.now() + 3600000,
    }))

    const capturedTokens = []
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedTokens.push(opts.headers.Authorization)
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedTokens[0]).toBe("Bearer ya29.cached-token")
  })

  it("skips expired cached token", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson())
    ctx.host.ls.discover.mockReturnValue(null)

    const cachePath = ctx.app.pluginDataDir + "/auth.json"
    ctx.host.fs.writeText(cachePath, JSON.stringify({
      accessToken: "ya29.expired-cache",
      expiresAtMs: Date.now() - 1000,
    }))

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer test-api-key-123")
  })

  it("skips expired proto token and falls back to next token", async () => {
    const ctx = makeCtx()
    const pastExpiry = Math.floor(Date.now() / 1000) - 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.expired-proto-token", "1//refresh", pastExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer test-api-key-123")
  })

  it("handles missing/corrupt cache file gracefully", async () => {
    const ctx = makeCtx()
    setupSqliteMock(ctx, makeAuthStatusJson())
    ctx.host.ls.discover.mockReturnValue(null)

    const cachePath = ctx.app.pluginDataDir + "/auth.json"
    ctx.host.fs.writeText(cachePath, "{bad json")

    let capturedAuth = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        capturedAuth = opts.headers.Authorization
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(capturedAuth).toBe("Bearer test-api-key-123")
  })

  it("Cloud Code skips models with isInternal flag", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test", "1//r", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            models: {
              "chat_20706": {
                model: "MODEL_CHAT_20706",
                isInternal: true,
                quotaInfo: { remainingFraction: 1, resetTime: "2026-02-08T10:00:00Z" },
              },
              "gemini-3-flash": {
                displayName: "Gemini 3 Flash",
                model: "MODEL_PLACEHOLDER_M18",
                quotaInfo: { remainingFraction: 0.9, resetTime: "2026-02-08T10:00:00Z" },
              },
            },
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)
    expect(labels).toContain("Gemini Flash")
    expect(labels).not.toContain("chat_20706")
    expect(labels).not.toContain("MODEL_CHAT_20706")
  })

  it("Cloud Code skips models with empty or missing displayName", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test", "1//r", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            models: {
              "tab_flash_lite": {
                displayName: "",
                model: "SOME_MODEL",
                quotaInfo: { remainingFraction: 1, resetTime: "2026-02-08T10:00:00Z" },
              },
              "no_display_name": {
                model: "ANOTHER_MODEL",
                quotaInfo: { remainingFraction: 1, resetTime: "2026-02-08T10:00:00Z" },
              },
              "gemini-3-pro": {
                displayName: "Gemini 3 Pro",
                model: "MODEL_PLACEHOLDER_M8",
                quotaInfo: { remainingFraction: 0.5, resetTime: "2026-02-08T10:00:00Z" },
              },
            },
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Gemini Pro"])
  })

  it("Cloud Code skips blacklisted model IDs", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test", "1//r", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            models: {
              "gemini-2.5-flash": {
                displayName: "Gemini 2.5 Flash",
                model: "MODEL_GOOGLE_GEMINI_2_5_FLASH",
                quotaInfo: { remainingFraction: 1, resetTime: "2026-02-08T10:00:00Z" },
              },
              "gemini-2.5-pro": {
                displayName: "Gemini 2.5 Pro",
                model: "MODEL_GOOGLE_GEMINI_2_5_PRO",
                quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T10:00:00Z" },
              },
              "claude-sonnet-4.5": {
                displayName: "Claude Sonnet 4.5",
                model: "MODEL_CLAUDE_4_5_SONNET",
                quotaInfo: { remainingFraction: 0.6, resetTime: "2026-02-08T10:00:00Z" },
              },
            },
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Claude"])
  })

  it("Cloud Code keeps non-blacklisted models with valid displayName", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test", "1//r", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            models: {
              "gemini-3-pro-high": {
                displayName: "Gemini 3 Pro (High)",
                model: "MODEL_PLACEHOLDER_M8",
                quotaInfo: { remainingFraction: 0.7, resetTime: "2026-02-08T10:00:00Z" },
              },
              "claude-opus-4-6-thinking": {
                displayName: "Claude Opus 4.6 (Thinking)",
                model: "MODEL_PLACEHOLDER_M26",
                quotaInfo: { remainingFraction: 1, resetTime: "2026-02-08T10:00:00Z" },
              },
              "gpt-oss-120b": {
                displayName: "GPT-OSS 120B (Medium)",
                model: "MODEL_OPENAI_GPT_OSS_120B_MEDIUM",
                quotaInfo: { remainingFraction: 0.9, resetTime: "2026-02-08T10:00:00Z" },
              },
            },
          }),
        }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Gemini Pro", "Claude"])
  })

  it("LS filters out blacklisted model IDs (Claude Opus 4.5)", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse({
      configs: [
        {
          label: "Gemini 3 Pro (High)",
          modelOrAlias: { model: "MODEL_PLACEHOLDER_M8" },
          quotaInfo: { remainingFraction: 0.75, resetTime: "2026-02-08T09:10:56Z" },
        },
        {
          label: "Claude Opus 4.5 (Thinking)",
          modelOrAlias: { model: "MODEL_PLACEHOLDER_M12" },
          quotaInfo: { remainingFraction: 0.8, resetTime: "2026-02-08T09:10:56Z" },
        },
        {
          label: "Claude Opus 4.6 (Thinking)",
          modelOrAlias: { model: "MODEL_PLACEHOLDER_M26" },
          quotaInfo: { remainingFraction: 0.6, resetTime: "2026-02-08T09:10:56Z" },
        },
      ],
    })
    setupLsMock(ctx, discovery, response)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const labels = result.lines.map((l) => l.label)
    expect(labels).toEqual(["Gemini Pro", "Claude"])
  })

  it("LS still takes priority over Cloud Code with proto tokens (no regression)", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    const protoB64 = makeProtobufBase64(ctx, "ya29.proto-token", "1//refresh", futureExpiry)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)
    const discovery = makeDiscovery()
    const response = makeUserStatusResponse()
    setupLsMock(ctx, discovery, response)
    setupSqliteMock(ctx, makeAuthStatusJson(), protoB64)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    const calls = ctx.host.http.request.mock.calls.map((c) => String(c[0].url))
    expect(calls.filter((u) => u.includes("fetchAvailableModels")).length).toBe(0)
    expect(calls.filter((u) => u.includes("oauth2.googleapis.com")).length).toBe(0)
  })

  it("throws when Cloud Code returns no models", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        return { status: 200, bodyText: JSON.stringify({}) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
  })

  it("handles refresh response missing access_token", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.will-fail", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    let oauthCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth2.googleapis.com")) {
        oauthCalls += 1
        return { status: 200, bodyText: JSON.stringify({ expires_in: 3600 }) }
      }
      if (url.includes("fetchAvailableModels")) {
        return { status: 401, bodyText: '{"error":"unauthorized"}' }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Antigravity and try again.")
    expect(oauthCalls).toBe(1)
  })

  it("continues to next Cloud Code base URL after non-2xx response", async () => {
    const ctx = makeCtx()
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600
    setupSqliteMock(ctx, makeAuthStatusJson(), makeProtobufBase64(ctx, "ya29.test-token", "1//refresh", futureExpiry))
    ctx.host.ls.discover.mockReturnValue(null)

    let ccCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("fetchAvailableModels")) {
        ccCalls += 1
        if (ccCalls === 1) return { status: 500, bodyText: "{}" }
        return { status: 200, bodyText: JSON.stringify(makeCloudCodeResponse()) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.length).toBeGreaterThan(0)
    expect(ccCalls).toBe(2)
  })
})
