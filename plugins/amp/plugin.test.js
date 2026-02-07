import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const SECRETS_FILE = "~/.local/share/amp/secrets.json"
const SECRETS_KEY = "apiKey@https://ampcode.com/"
const API_URL = "https://ampcode.com/api/internal"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function writeSecrets(ctx, apiKey) {
  var obj = {}
  obj[SECRETS_KEY] = apiKey || "test-api-key"
  ctx.host.fs.writeText(SECRETS_FILE, JSON.stringify(obj))
}

function balanceResponse(displayText) {
  return {
    status: 200,
    bodyText: JSON.stringify({ ok: true, result: { displayText: displayText } }),
  }
}

function standardDisplayText(opts) {
  opts = opts || {}
  var remaining = opts.remaining !== undefined ? opts.remaining : 1.66
  var total = opts.total !== undefined ? opts.total : 20
  var rate = opts.rate !== undefined ? opts.rate : 0.83
  var text = "Signed in as user@test.com (testuser)\n"
  text += "Amp Free: $" + remaining + "/$" + total + " remaining (replenishes +$" + rate + "/hour)"
  if (opts.bonus !== false) {
    var pct = opts.bonusPct || 100
    var days = opts.bonusDays || 2
    text += " [+" + pct + "% bonus for " + days + " more days]"
  }
  text += " - https://ampcode.com/settings#amp-free\n"
  var credits = opts.credits !== undefined ? opts.credits : 0
  text += "Individual credits: $" + credits + " remaining - https://ampcode.com/settings"
  return text
}

describe("amp plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  // --- Auth ---

  it("throws when secrets file not found", async () => {
    var ctx = makeCtx()
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Amp not installed")
  })

  it("throws when secrets file has no api key", async () => {
    var ctx = makeCtx()
    ctx.host.fs.writeText(SECRETS_FILE, JSON.stringify({ other: "value" }))
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Amp not installed")
  })

  it("throws on invalid JSON in secrets file", async () => {
    var ctx = makeCtx()
    ctx.host.fs.writeText(SECRETS_FILE, "{bad json")
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Amp not installed")
  })

  // --- API request ---

  it("sends POST with Bearer auth to api/internal", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx, "my-api-key")
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText()))
    var plugin = await loadPlugin()
    plugin.probe(ctx)
    var call = ctx.host.http.request.mock.calls[0][0]
    expect(call.method).toBe("POST")
    expect(call.url).toBe(API_URL)
    expect(call.headers.Authorization).toBe("Bearer my-api-key")
    expect(call.headers["Content-Type"]).toBe("application/json")
    var body = JSON.parse(call.bodyText)
    expect(body.method).toBe("userDisplayBalanceInfo")
    expect(body.params).toEqual({})
  })

  // --- HTTP errors ---

  it("throws on HTTP 401", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws on HTTP 403", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue({ status: 403, bodyText: "" })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws with error detail on non-2xx with JSON error", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue({
      status: 402,
      bodyText: JSON.stringify({ error: { message: "Credits required for this feature." } }),
    })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Credits required for this feature.")
  })

  it("throws generic error on HTTP 500", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed (HTTP 500)")
  })

  it("throws on network error", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockImplementation(() => { throw new Error("ECONNREFUSED") })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed. Check your connection.")
  })

  // --- Response structure errors ---

  it("throws when response has no ok field", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: JSON.stringify({ result: {} }) })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })

  it("throws when response has no displayText", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ ok: true, result: {} }),
    })
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })

  it("throws when displayText has no balance pattern", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse("Some random text with no data"))
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })

  // --- Balance parsing ---

  it("parses standard balance text", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      remaining: 1.66, total: 20, rate: 0.83,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    var line = result.lines[0]
    expect(line.type).toBe("progress")
    expect(line.label).toBe("Free")
    expect(line.used).toBeCloseTo(18.34, 2)
    expect(line.limit).toBe(20)
    expect(line.format.kind).toBe("dollars")
  })

  it("parses balance with no bonus bracket", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      remaining: 10, total: 20, rate: 0.83, bonus: false,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.lines.length).toBe(1)
    expect(result.lines[0].used).toBe(10)
  })

  it("includes bonus text line when present", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      bonusPct: 100, bonusDays: 2,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    var bonusLine = result.lines.find(function (l) { return l.label === "Bonus" })
    expect(bonusLine).toBeTruthy()
    expect(bonusLine.value).toBe("+100% for 2d")
  })

  it("includes credits text line when credits > 0", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      credits: 5.50,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    var creditsLine = result.lines.find(function (l) { return l.label === "Credits" })
    expect(creditsLine).toBeTruthy()
    expect(creditsLine.value).toBe("$5.50")
  })

  it("omits credits line when credits are zero", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      credits: 0,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    var creditsLine = result.lines.find(function (l) { return l.label === "Credits" })
    expect(creditsLine).toBeUndefined()
  })

  it("clamps used to 0 when remaining exceeds total", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      remaining: 25, total: 20,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.lines[0].used).toBe(0)
  })

  // --- Reset time and period ---

  it("returns resetsAt and periodDurationMs", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      remaining: 1.66, total: 20, rate: 0.83,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    var line = result.lines[0]
    expect(line.resetsAt).toBeTruthy()
    expect(line.periodDurationMs).toBe(24 * 3600 * 1000)
  })

  it("returns null resetsAt when nothing used", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      remaining: 20, total: 20, rate: 0.83,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.lines[0].used).toBe(0)
  })

  it("returns null resetsAt when hourly rate is zero", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      remaining: 10, total: 20, rate: 0,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.lines[0].used).toBe(10)
  })

  // --- Plan ---

  it("returns Free as plan", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText()))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.plan).toBe("Free")
  })

  // --- Credits only ---

  it("handles credits-only user", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    var text = "Signed in as user@test.com (testuser)\nIndividual credits: $25.50 remaining - https://ampcode.com/settings"
    ctx.host.http.request.mockReturnValue(balanceResponse(text))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.plan).toBe("Credits")
    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Credits")
    expect(result.lines[0].value).toBe("$25.50")
  })

  it("shows both free tier and credits when both present", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse(standardDisplayText({
      credits: 10,
    })))
    var plugin = await loadPlugin()
    var result = plugin.probe(ctx)
    expect(result.plan).toBe("Free")
    var progressLine = result.lines.find(function (l) { return l.type === "progress" })
    var creditsLine = result.lines.find(function (l) { return l.label === "Credits" })
    expect(progressLine).toBeTruthy()
    expect(creditsLine).toBeTruthy()
    expect(creditsLine.value).toBe("$10.00")
  })

  it("throws when display text has neither balance nor credits", async () => {
    var ctx = makeCtx()
    writeSecrets(ctx)
    ctx.host.http.request.mockReturnValue(balanceResponse("Signed in as user@test.com (testuser)"))
    var plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })
})
