import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const CLOUD_COMPAT_VERSION = "1.108.2"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeAuthStatus(apiKey = "sk-ws-01-test") {
  return JSON.stringify([{ value: JSON.stringify({ apiKey }) }])
}

function makeQuotaResponse(overrides) {
  const base = {
    userStatus: {
      planStatus: {
      planInfo: {
        planName: "Teams",
        billingStrategy: "BILLING_STRATEGY_QUOTA",
      },
      dailyQuotaRemainingPercent: 100,
      weeklyQuotaRemainingPercent: 100,
      overageBalanceMicros: "964220000",
      dailyQuotaResetAtUnix: "1774080000",
      weeklyQuotaResetAtUnix: "1774166400",
    },
  },
}

  if (overrides) {
    base.userStatus.planStatus = {
      ...base.userStatus.planStatus,
      ...overrides,
      planInfo: {
        ...base.userStatus.planStatus.planInfo,
        ...(overrides.planInfo || {}),
      },
    }
  }

  return base
}

function setupCloudMock(ctx, { stableAuth, nextAuth, stableResponse, nextResponse }) {
  ctx.host.sqlite.query.mockImplementation((db, sql) => {
    if (!String(sql).includes("windsurfAuthStatus")) return "[]"
    if (String(db).includes("Windsurf - Next")) {
      return nextAuth ? makeAuthStatus(nextAuth) : "[]"
    }
    if (String(db).includes("Windsurf/User/globalStorage")) {
      return stableAuth ? makeAuthStatus(stableAuth) : "[]"
    }
    return "[]"
  })

  ctx.host.http.request.mockImplementation((reqOpts) => {
    const body = JSON.parse(String(reqOpts.bodyText || "{}"))
    const ideName = body.metadata && body.metadata.ideName
    if (ideName === "windsurf-next") {
      if (nextResponse instanceof Error) throw nextResponse
      return nextResponse || { status: 500, bodyText: "{}" }
    }
    if (ideName === "windsurf") {
      if (stableResponse instanceof Error) throw stableResponse
      return stableResponse || { status: 500, bodyText: "{}" }
    }
    return { status: 500, bodyText: "{}" }
  })
}

describe("windsurf plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("renders quota-only lines from the cloud response", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: { status: 200, bodyText: JSON.stringify(makeQuotaResponse()) },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Teams")
    expect(result.lines).toHaveLength(3)

    expect(result.lines.find((line) => line.label === "Plan")).toBeUndefined()

    expect(result.lines.find((line) => line.label === "Daily quota")).toEqual({
      type: "progress",
      label: "Daily quota",
      used: 0,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: "2026-03-21T08:00:00.000Z",
      periodDurationMs: 24 * 60 * 60 * 1000,
    })

    expect(result.lines.find((line) => line.label === "Weekly quota")).toEqual({
      type: "progress",
      label: "Weekly quota",
      used: 0,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: "2026-03-22T08:00:00.000Z",
      periodDurationMs: 7 * 24 * 60 * 60 * 1000,
    })

    expect(result.lines.find((line) => line.label === "Extra usage balance")).toEqual({
      type: "text",
      label: "Extra usage balance",
      value: "$964.22",
    })
    expect(result.lines.find((line) => line.label === "Plan window")).toBeUndefined()
  })

  it("uses windsurf-next metadata when only the Next auth DB is available", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      nextAuth: "sk-ws-01-next",
      nextResponse: {
        status: 200,
        bodyText: JSON.stringify(makeQuotaResponse({ planInfo: { planName: "Pro" } })),
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")

    const sentBody = JSON.parse(String(ctx.host.http.request.mock.calls[0][0].bodyText))
    expect(sentBody.metadata.ideName).toBe("windsurf-next")
    expect(sentBody.metadata.extensionName).toBe("windsurf-next")
    expect(sentBody.metadata.ideVersion).toBe(CLOUD_COMPAT_VERSION)
    expect(sentBody.metadata.extensionVersion).toBe(CLOUD_COMPAT_VERSION)
  })

  it("prefers Windsurf over Windsurf Next when both auth DBs are available", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      nextAuth: "sk-ws-01-next",
      stableResponse: { status: 200, bodyText: JSON.stringify(makeQuotaResponse()) },
      nextResponse: {
        status: 200,
        bodyText: JSON.stringify(makeQuotaResponse({ planInfo: { planName: "Next" } })),
      },
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.http.request).toHaveBeenCalledTimes(1)
    const sentBody = JSON.parse(String(ctx.host.http.request.mock.calls[0][0].bodyText))
    expect(sentBody.metadata.ideName).toBe("windsurf")
  })

  it("calculates percentage usage from remaining daily and weekly quota", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify(
          makeQuotaResponse({
            dailyQuotaRemainingPercent: 65,
            weeklyQuotaRemainingPercent: 25,
          })
        ),
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Daily quota")?.used).toBe(35)
    expect(result.lines.find((line) => line.label === "Weekly quota")?.used).toBe(75)
  })

  it("clamps out-of-range quota percentages into the 0-100 display range", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify(
          makeQuotaResponse({
            dailyQuotaRemainingPercent: -20,
            weeklyQuotaRemainingPercent: 150,
          })
        ),
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Daily quota")?.used).toBe(100)
    expect(result.lines.find((line) => line.label === "Weekly quota")?.used).toBe(0)
  })

  it("falls back to Unknown plan and clamps negative extra usage balance to zero", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify(
          makeQuotaResponse({
            planInfo: { planName: "   " },
            overageBalanceMicros: "-5000000",
          })
        ),
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Unknown")
    expect(result.lines.find((line) => line.label === "Extra usage balance")?.value).toBe("$0.00")
  })

  it("falls back to Unknown plan when planInfo is missing", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify(
          makeQuotaResponse({
            planInfo: { planName: null },
          })
        ),
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Unknown")
  })

  it("does not probe the local language server or localhost", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: { status: 200, bodyText: JSON.stringify(makeQuotaResponse()) },
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.ls.discover).not.toHaveBeenCalled()
    const urls = ctx.host.http.request.mock.calls.map((call) => String(call[0].url))
    expect(urls.every((url) => url.startsWith("https://server.self-serve.windsurf.com/"))).toBe(true)
    expect(urls.some((url) => url.includes("127.0.0.1"))).toBe(false)
  })

  it("throws the login hint when no API key is available", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf or sign in and try again.")
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })

  it("treats SQLite read errors as missing API key and logs a warning", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation(() => {
      throw new Error("db unavailable")
    })

    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("Start Windsurf or sign in and try again.")
    expect(ctx.host.log.warn).toHaveBeenCalledWith(expect.stringContaining("failed to read API key"))
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })

  it("throws quota unavailable when the cloud returns non-2xx for every variant", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      nextAuth: "sk-ws-01-next",
      stableResponse: { status: 503, bodyText: "{}" },
      nextResponse: { status: 401, bodyText: "{}" },
    })

    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("Windsurf quota data unavailable. Try again later.")
    expect(ctx.host.log.warn).toHaveBeenCalledWith(expect.stringContaining("cloud request returned status 503"))
    expect(ctx.host.log.warn).toHaveBeenCalledWith(expect.stringContaining("cloud request returned status 401"))
  })

  it("falls through to the next variant when a cloud request throws", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      nextAuth: "sk-ws-01-next",
      stableResponse: new Error("network error"),
      nextResponse: { status: 200, bodyText: JSON.stringify(makeQuotaResponse({ planInfo: { planName: "Pro" } })) },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(ctx.host.log.warn).toHaveBeenCalledWith(expect.stringContaining("cloud request failed for windsurf"))
  })

  it("throws quota unavailable when reset timestamps cannot be converted", async () => {
    const ctx = makeCtx()
    ctx.util.toIso = vi.fn(() => null)
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: { status: 200, bodyText: JSON.stringify(makeQuotaResponse()) },
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Windsurf quota data unavailable. Try again later.")
  })

  it("throws quota unavailable when a progress line cannot be built", async () => {
    const ctx = makeCtx()
    const originalProgress = ctx.line.progress
    ctx.line.progress = vi.fn((opts) => {
      if (opts.label === "Daily quota") return null
      return originalProgress(opts)
    })
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: { status: 200, bodyText: JSON.stringify(makeQuotaResponse()) },
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Windsurf quota data unavailable. Try again later.")
  })

  it("throws quota unavailable when quota fields are missing", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify(makeQuotaResponse({ dailyQuotaRemainingPercent: undefined })),
      },
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Windsurf quota data unavailable. Try again later.")
  })

  it("throws quota unavailable when planStatus is null", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify({ userStatus: { planStatus: null } }),
      },
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Windsurf quota data unavailable. Try again later.")
  })

  it("throws quota unavailable for a legacy credit-only payload", async () => {
    const ctx = makeCtx()
    setupCloudMock(ctx, {
      stableAuth: "sk-ws-01-stable",
      stableResponse: {
        status: 200,
        bodyText: JSON.stringify({
          userStatus: {
            planStatus: {
              planInfo: { planName: "Teams" },
              availablePromptCredits: 50000,
              availableFlexCredits: 100000,
              planStart: "2026-03-18T09:07:17Z",
              planEnd: "2026-04-18T09:07:17Z",
            },
          },
        }),
      },
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Windsurf quota data unavailable. Try again later.")
  })
})
