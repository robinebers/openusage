import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

// --- Fixtures ---

function makeDiscovery(overrides) {
  return Object.assign(
    { pid: 12345, csrf: "test-csrf", ports: [42001], extensionPort: null },
    overrides
  )
}

function makeAuthStatus(apiKey) {
  return JSON.stringify([{ value: JSON.stringify({ apiKey: apiKey || "sk-ws-01-test" }) }])
}

function makeLsResponse(overrides) {
  var base = {
    userStatus: {
      planStatus: {
        planInfo: { planName: "Teams" },
        planStart: "2026-01-18T09:07:17Z",
        planEnd: "2026-02-18T09:07:17Z",
        availablePromptCredits: 50000,
        usedPromptCredits: 4700,
        availableFlowCredits: 120000,
        usedFlowCredits: 0,
        availableFlexCredits: 2675000,
        usedFlexCredits: 175550,
      },
    },
  }
  if (overrides) {
    Object.assign(base.userStatus.planStatus, overrides)
  }
  return base
}

function setupLsMock(ctx, discovery, apiKey, responseBody, opts) {
  var stateDb = (opts && opts.stateDb) || "Windsurf"
  ctx.host.ls.discover.mockImplementation((discoverOpts) => {
    // Match the right variant by marker
    var marker = discoverOpts.markers[0]
    if (marker === "windsurf" && stateDb === "Windsurf") return discovery
    if (marker === "windsurf-next" && stateDb === "Windsurf - Next") return discovery
    return null
  })
  ctx.host.sqlite.query.mockImplementation((db, sql) => {
    if (String(sql).includes("windsurfAuthStatus") && String(db).includes(stateDb)) {
      return makeAuthStatus(apiKey)
    }
    return "[]"
  })
  ctx.host.http.request.mockImplementation((reqOpts) => {
    if (String(reqOpts.url).includes("GetUnleashData")) {
      return { status: 200, bodyText: "{}" }
    }
    return { status: 200, bodyText: JSON.stringify(responseBody) }
  })
}

// --- Tests ---

describe("windsurf plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when LS not found and no cache", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(null)
    ctx.host.sqlite.query.mockReturnValue("[]")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf and try again.")
  })

  it("returns credits from LS with billing pacing", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-test", makeLsResponse())

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Teams")

    // Values divided by 100 for display (API stores in hundredths)
    const prompt = result.lines.find((l) => l.label === "Prompt credits")
    expect(prompt).toBeTruthy()
    expect(prompt.used).toBe(47)       // 4700 / 100
    expect(prompt.limit).toBe(500)     // 50000 / 100
    expect(prompt.resetsAt).toBe("2026-02-18T09:07:17Z")
    expect(prompt.periodDurationMs).toBeGreaterThan(0)

    expect(result.lines.find((l) => l.label === "Flow credits")).toBeFalsy()

    const flex = result.lines.find((l) => l.label === "Flex credits")
    expect(flex).toBeTruthy()
    expect(flex.used).toBe(1755.5)     // 175550 / 100
    expect(flex.limit).toBe(26750)     // 2675000 / 100
    expect(flex.resetsAt).toBeUndefined()
    expect(flex.periodDurationMs).toBeUndefined()
  })

  it("flex credits have no billing cycle (non-renewing)", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-test", makeLsResponse())

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const prompt = result.lines.find((l) => l.label === "Prompt credits")
    expect(prompt.resetsAt).toBe("2026-02-18T09:07:17Z")
    expect(prompt.periodDurationMs).toBeGreaterThan(0)

    const flex = result.lines.find((l) => l.label === "Flex credits")
    expect(flex.resetsAt).toBeUndefined()
    expect(flex.periodDurationMs).toBeUndefined()
  })

  it("skips credit lines with negative available (unlimited)", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-test", makeLsResponse({
      availablePromptCredits: -1,
      availableFlexCredits: 100000,
      usedFlexCredits: 500,
    }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Prompt credits")).toBeFalsy()
    expect(result.lines.find((l) => l.label === "Flex credits")).toBeTruthy()
  })

  it("sends apiKey in metadata", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-mykey", makeLsResponse())

    let sentBody = null
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUserStatus")) {
        sentBody = reqOpts.bodyText
      }
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(sentBody).toBeTruthy()
    const parsed = JSON.parse(sentBody)
    expect(parsed.metadata.apiKey).toBe("sk-ws-01-mykey")
    expect(parsed.metadata.ideName).toBe("windsurf")
  })

  it("returns null from LS when no API key", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery())
    ctx.host.sqlite.query.mockReturnValue("[]")
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    // No API key → LS probe returns null → falls back to cache → no cache → throws
    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf and try again.")
  })

  it("calculates billing period duration from planStart/planEnd", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-test", makeLsResponse())

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const prompt = result.lines.find((l) => l.label === "Prompt credits")
    expect(prompt.used).toBe(47) // 4700 / 100
    const expected = Date.parse("2026-02-18T09:07:17Z") - Date.parse("2026-01-18T09:07:17Z")
    expect(prompt.periodDurationMs).toBe(expected)
  })

  // --- Windsurf Next tests ---

  it("falls back to Windsurf Next when Windsurf LS not found", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-next", makeLsResponse({
      planInfo: { planName: "Pro" },
    }), { stateDb: "Windsurf - Next" })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
  })

  it("sends windsurf-next as ideName for Windsurf Next variant", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-next", makeLsResponse(), { stateDb: "Windsurf - Next" })

    let sentBody = null
    const origHttp = ctx.host.http.request
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUserStatus")) {
        sentBody = reqOpts.bodyText
      }
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(sentBody).toBeTruthy()
    const parsed = JSON.parse(sentBody)
    expect(parsed.metadata.ideName).toBe("windsurf-next")
    expect(parsed.metadata.extensionName).toBe("windsurf-next")
  })

  it("reads API key from Windsurf Next SQLite path", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-next", makeLsResponse(), { stateDb: "Windsurf - Next" })

    let queriedDb = null
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("windsurfAuthStatus")) {
        queriedDb = db
        return makeAuthStatus("sk-ws-01-next")
      }
      return "[]"
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(queriedDb).toContain("Windsurf - Next")
  })

  it("prefers Windsurf over Windsurf Next when both available", async () => {
    const ctx = makeCtx()
    // Both variants return valid discoveries
    ctx.host.ls.discover.mockImplementation((discoverOpts) => {
      return makeDiscovery()
    })
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("windsurfAuthStatus")) {
        return makeAuthStatus("sk-ws-01-both")
      }
      return "[]"
    })
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
    })

    let sentBodies = []
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUserStatus")) {
        sentBodies.push(reqOpts.bodyText)
      }
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    // Should use windsurf (first variant) and never try windsurf-next
    expect(sentBodies.length).toBe(1)
    const parsed = JSON.parse(sentBodies[0])
    expect(parsed.metadata.ideName).toBe("windsurf")
  })

  it("falls back from https to http when probing LS port", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-test", makeLsResponse())

    ctx.host.http.request.mockImplementation((reqOpts) => {
      const url = String(reqOpts.url)
      if (url.includes("GetUnleashData")) {
        if (url.startsWith("https://")) throw new Error("self-signed cert")
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Teams")
    const unleashCalls = ctx.host.http.request.mock.calls
      .map((call) => String(call[0]?.url))
      .filter((url) => url.includes("GetUnleashData"))
    expect(unleashCalls.some((url) => url.startsWith("http://"))).toBe(true)
  })

  it("uses extensionPort when direct probes fail for all discovered ports", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery({ ports: [42001], extensionPort: 42002 })
    setupLsMock(ctx, discovery, "sk-ws-01-test", makeLsResponse())

    ctx.host.http.request.mockImplementation((reqOpts) => {
      const url = String(reqOpts.url)
      if (url.includes("GetUnleashData")) {
        throw new Error("probe failed")
      }
      if (url.includes(":42002/") && url.includes("GetUserStatus")) {
        return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
      }
      return { status: 500, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Teams")
  })

  it("returns unlimited badge when all credit buckets are non-positive", async () => {
    const ctx = makeCtx()
    setupLsMock(
      ctx,
      makeDiscovery(),
      "sk-ws-01-test",
      makeLsResponse({ availablePromptCredits: -1, availableFlexCredits: -1 })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines).toEqual([{ type: "badge", label: "Credits", text: "Unlimited" }])
  })

  it("clamps negative used credits to zero", async () => {
    const ctx = makeCtx()
    setupLsMock(
      ctx,
      makeDiscovery(),
      "sk-ws-01-test",
      makeLsResponse({ availablePromptCredits: 50000, usedPromptCredits: -500, availableFlexCredits: -1 })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const prompt = result.lines.find((l) => l.label === "Prompt credits")
    expect(prompt.used).toBe(0)
  })

  it("omits billing period when plan dates are invalid", async () => {
    const ctx = makeCtx()
    setupLsMock(
      ctx,
      makeDiscovery(),
      "sk-ws-01-test",
      makeLsResponse({ planStart: "not-a-date", planEnd: "2026-02-18T09:07:17Z", availableFlexCredits: -1 })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const prompt = result.lines.find((l) => l.label === "Prompt credits")
    expect(prompt.periodDurationMs).toBeUndefined()
  })

  it("throws when GetUserStatus returns non-2xx", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery(), "sk-ws-01-test", makeLsResponse())

    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 500, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf and try again.")
  })

  it("treats missing apiKey in SQLite auth payload as unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.ls.discover.mockReturnValue(makeDiscovery())
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: JSON.stringify({}) }]))
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUnleashData")) {
        return { status: 200, bodyText: "{}" }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf and try again.")
  })

  it("uses extensionPort when ports list is missing", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery({ ports: undefined, extensionPort: 42002 })
    setupLsMock(ctx, discovery, "sk-ws-01-test", makeLsResponse())
    ctx.host.http.request.mockImplementation((reqOpts) => {
      const url = String(reqOpts.url)
      if (url.includes(":42002/") && url.includes("GetUserStatus")) {
        return { status: 200, bodyText: JSON.stringify(makeLsResponse()) }
      }
      if (url.includes("GetUnleashData")) {
        return { status: 500, bodyText: "{}" }
      }
      return { status: 500, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Teams")
  })

  it("fails when all probes fail and extensionPort is absent", async () => {
    const ctx = makeCtx()
    const discovery = makeDiscovery({ ports: [42001], extensionPort: null })
    setupLsMock(ctx, discovery, "sk-ws-01-test", makeLsResponse())
    ctx.host.http.request.mockImplementation((reqOpts) => {
      if (String(reqOpts.url).includes("GetUnleashData")) {
        throw new Error("probe failed")
      }
      return { status: 500, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf and try again.")
  })

  it("handles sparse userStatus payload and returns unlimited badge", async () => {
    const ctx = makeCtx()
    setupLsMock(ctx, makeDiscovery({ extra: null }), "sk-ws-01-test", { userStatus: {} })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines).toEqual([{ type: "badge", label: "Credits", text: "Unlimited" }])
  })

})
