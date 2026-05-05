import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

var SECRETS_FILE = "~/.commandcode/auth.json"
var SECRETS_KEY = "apiKey"
var CREDITS_URL = "https://api.commandcode.ai/alpha/billing/credits"
var SUBS_URL = "https://api.commandcode.ai/alpha/billing/subscriptions"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function writeSecrets(ctx, apiKey) {
  var obj = {}
  obj[SECRETS_KEY] = apiKey || "test-api-key"
  ctx.host.fs.writeText(SECRETS_FILE, JSON.stringify(obj))
}

function creditsResponse(monthlyCredits) {
  return {
    status: 200,
    bodyText: JSON.stringify({
      credits: {
        belowThreshold: false,
        creditThreshold: 0,
        monthlyCredits: monthlyCredits,
        purchasedCredits: 0,
        freeCredits: 0,
      },
    }),
  }
}

function subsResponse(overrides) {
  overrides = overrides || {}
  return {
    status: 200,
    bodyText: JSON.stringify({
      success: true,
      data: {
        id: "sub_redacted",
        status: "active",
        userId: "test-user",
        orgId: null,
        createdAt: "2026-03-03T03:03:03.000Z",
        priceId: "price_redacted",
        metadata: { commandCode: "true" },
        quantity: 1,
        cancelAtPeriodEnd: false,
        currentPeriodStart: "2026-03-03T03:03:03.000Z",
        currentPeriodEnd: overrides.currentPeriodEnd || "2026-04-03T03:03:03.000Z",
        endedAt: null,
        cancelAt: null,
        canceledAt: null,
        planId: overrides.planId || "individual-go",
      },
    }),
  }
}

describe("command plugin", function () {
  beforeEach(function () {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  // --- Auth ---

  it("throws when secrets file not found", async function () {
    var ctx = makeCtx()
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("CommandCode not installed")
  })

  it("throws when secrets file has no api key", async function () {
    var ctx = makeCtx()
    ctx.host.fs.writeText(SECRETS_FILE, JSON.stringify({ other: "value" }))
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("CommandCode not installed")
  })

  it("throws on invalid JSON in secrets file", async function () {
    var ctx = makeCtx()
    ctx.host.fs.writeText(SECRETS_FILE, "{bad json")
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("CommandCode not installed")
  })

  // --- API requests ---

  it("sends GET to credits URL with Bearer auth", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx, "my-api-key")
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce(subsResponse())
    var plugin = await loadPlugin()
    await plugin.probe(ctx)
    var call = ctx.host.http.request.mock.calls[0][0]
    expect(call.method).toBe("GET")
    expect(call.url).toBe(CREDITS_URL)
    expect(call.headers.Authorization).toBe("Bearer my-api-key")
    expect(call.headers["Content-Type"]).toBe("application/json")
  })

  it("sends GET to subscriptions URL with Bearer auth", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx, "my-api-key")
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce(subsResponse())
    var plugin = await loadPlugin()
    await plugin.probe(ctx)
    var call = ctx.host.http.request.mock.calls[1][0]
    expect(call.method).toBe("GET")
    expect(call.url).toBe(SUBS_URL)
    expect(call.headers.Authorization).toBe("Bearer my-api-key")
  })

  // --- HTTP errors: credits ---

  it("throws on credits HTTP 401", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce({ status: 401, bodyText: "" })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Session expired")
  })

  it("throws on credits HTTP 403", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce({ status: 403, bodyText: "" })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Session expired")
  })

  it("throws with error detail on credits non-2xx with JSON error", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce({
      status: 402,
      bodyText: JSON.stringify({ error: { message: "Credits required." } }),
    })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Credits required.")
  })

  it("throws on credits HTTP 500", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce({ status: 500, bodyText: "" })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Request failed (HTTP 500)")
  })

  it("throws on credits network error", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockImplementationOnce(function () { throw new Error("ECONNREFUSED") })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Request failed. Check your connection.")
  })

  // --- Response structure errors: credits ---

  it("throws when credits response has no credits field", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce({ status: 200, bodyText: JSON.stringify({}) })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Could not parse usage data")
  })

  it("throws when monthlyCredits is not a number", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce({
      status: 200,
      bodyText: JSON.stringify({ credits: { monthlyCredits: "not-a-number" } }),
    })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Could not parse usage data")
  })

  // --- HTTP errors: subscriptions ---

  it("throws on subscriptions HTTP 401", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce({ status: 401, bodyText: "" })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Session expired")
  })

  it("throws on subscriptions HTTP 500", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce({ status: 500, bodyText: "" })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Request failed (HTTP 500)")
  })

  it("throws on subscriptions network error", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockImplementationOnce(function () { throw new Error("ECONNREFUSED") })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Request failed. Check your connection.")
  })

  it("throws when subscriptions response is missing success", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce({ status: 200, bodyText: JSON.stringify({ data: {} }) })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Could not parse subscription data")
  })

  it("throws when subscriptions response is missing data", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce({ status: 200, bodyText: JSON.stringify({ success: true }) })
    var plugin = await loadPlugin()
    await expect(plugin.probe(ctx)).rejects.toThrow("Could not parse subscription data")
  })

  // --- Progress line ---

  it("returns plan and progress line", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    // individual-go: total=10, remaining=3 → used=7
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(3))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-go" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.plan).toBe("individual-go")
    expect(result.lines.length).toBe(2)
    var line = result.lines[0]
    expect(line.label).toBe("Go")
    expect(line.used).toBe(7)
    expect(line.limit).toBe(10)
    expect(line.format.kind).toBe("dollars")
    var pctLine = result.lines[1]
    expect(pctLine.label).toBe("Monthly Quota")
    expect(pctLine.used).toBe(70)
    expect(pctLine.limit).toBe(100)
    expect(pctLine.format.kind).toBe("percent")
  })

  it("returns resetsAt and periodDurationMs", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(3))
    ctx.host.http.request.mockReturnValueOnce(subsResponse())
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    var line = result.lines[0]
    expect(line.resetsAt).toBeTruthy()
    expect(line.periodDurationMs).toBe(30 * 24 * 3600 * 1000)
  })

  it("clamaps used to 0 when remaining exceeds total", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(15))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-go" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[0].used).toBe(0)
    expect(result.lines[1].used).toBe(0)
  })

  it("returns percent line with correct calculation", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    // individual-pro: total=30, remaining=12 → used=18 → 60%
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(12))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-pro" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines.length).toBe(2)
    var pctLine = result.lines[1]
    expect(pctLine.label).toBe("Monthly Quota")
    expect(pctLine.used).toBe(60)
    expect(pctLine.limit).toBe(100)
    expect(pctLine.format.kind).toBe("percent")
  })

  it("clamaps percent line to 100 when used exceeds total", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    // individual-go: total=10, remaining=-5 → used=15 → 150% → clamps to 100
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(-5))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-go" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[1].used).toBe(100)
    expect(result.lines[1].limit).toBe(100)
  })

  // --- Plan labels ---

  it("displays Go for individual-go", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-go" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Go")
  })

  it("displays Pro for individual-pro", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(15))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-pro" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Pro")
    expect(result.lines[0].used).toBe(15)
    expect(result.lines[0].limit).toBe(30)
  })

  it("displays Max for individual-max", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(50))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-max" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Max")
    expect(result.lines[0].used).toBe(100)
    expect(result.lines[0].limit).toBe(150)
  })

  it("displays Ultra for individual-ultra", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(200))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-ultra" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Ultra")
    expect(result.lines[0].used).toBe(100)
    expect(result.lines[0].limit).toBe(300)
  })

  it("displays Teams Pro for teams-pro", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(10))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "teams-pro" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Teams Pro")
    expect(result.lines[0].used).toBe(30)
    expect(result.lines[0].limit).toBe(40)
  })

  it("falls back to capitalized planId for unknown plans", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(0))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "enterprise-custom" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    // unknown plan has no limit → no progress line
    expect(result.lines.length).toBe(0)
  })

  it("returns plan from subscriptions data", async function () {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValueOnce(creditsResponse(5))
    ctx.host.http.request.mockReturnValueOnce(subsResponse({ planId: "individual-pro" }))
    var plugin = await loadPlugin()
    var result = await plugin.probe(ctx)
    expect(result.plan).toBe("individual-pro")
  })
})
