import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const API_URL = "https://crof.ai/usage_api/"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeSuccessResponse(credits, usableRequests, requestsPlan = 500) {
  const body = { credits: credits }
  if (usableRequests !== undefined) {
    body.usable_requests = usableRequests
  }
  if (requestsPlan !== undefined) {
    body.requests_plan = requestsPlan
  }
  return { status: 200, bodyText: JSON.stringify(body) }
}

describe("crofai plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when CROFAI_API_KEY is missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "No CROFAI_API_KEY found. Set up environment variable first."
    )
  })

  it("throws when CROFAI_API_KEY is empty", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "No CROFAI_API_KEY found. Set up environment variable first."
    )
  })

  it("throws when CROFAI_API_KEY is whitespace", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("   ")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "No CROFAI_API_KEY found. Set up environment variable first."
    )
  })

  it("sends GET with Bearer auth to correct URL", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(10, 100))
    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.method).toBe("GET")
    expect(call.url).toBe(API_URL)
    expect(call.headers.Authorization).toBe("Bearer test-api-key")
    expect(call.headers.Accept).toBe("application/json")
    expect(call.timeoutMs).toBe(10000)
  })

  it("throws on network error", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("ECONNREFUSED")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage request failed. Check your connection."
    )
  })

  it("throws on HTTP 401", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "API key invalid. Check your CrofAI API key."
    )
  })

  it("throws on HTTP 403", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 403, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "API key invalid. Check your CrofAI API key."
    )
  })

  it("throws on HTTP 500", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage request failed (HTTP 500). Try again later."
    )
  })

  it("throws on HTTP 300 (non-2xx boundary)", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 300, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage request failed (HTTP 300). Try again later."
    )
  })

  it("throws on unparseable JSON", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "not-json" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws on null bodyText", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: null })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws on empty bodyText", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws when response body is an array", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: JSON.stringify([1, 2]) })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws when response body contains Infinity", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: '{"credits":Infinity,"usable_requests":10,"requests_plan":500}',
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws when response body contains NaN", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: '{"credits":NaN,"usable_requests":10,"requests_plan":500}',
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws when usable_requests is a boolean", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: 10, usable_requests: true, requests_plan: 500 }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("returns credits and requests progress lines", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(12.3456, 321, 500))
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(2)

    const requestsLine = result.lines[0]
    expect(requestsLine.type).toBe("progress")
    expect(requestsLine.label).toBe("Requests")
    expect(requestsLine.used).toBe(179)
    expect(requestsLine.limit).toBe(500)
    expect(requestsLine.format).toEqual({ kind: "count", suffix: "requests" })

    const creditsLine = result.lines[1]
    expect(creditsLine.type).toBe("text")
    expect(creditsLine.label).toBe("Credits")
    expect(creditsLine.value).toBe("$12.35")
  })

  it("shows credits line as $0.00 when credits is zero", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(0, 100))
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const creditsLine = result.lines.find((l) => l.label === "Credits")
    expect(creditsLine).toBeDefined()
    expect(creditsLine.value).toBe("$0.00")
    expect(result.lines.length).toBe(2)
  })

  it("omits credits line when credits is negative", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(-5, 100))
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Credits")).toBeUndefined()
  })

  it("omits requests line when usable_requests is null", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(5, null))
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Credits")
  })

  it("omits requests line when usable_requests is absent", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: 5, requests_plan: 500 }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Credits")
  })

  it("throws when requests_plan is absent", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: 5, usable_requests: 10 }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("omits requests line when request fields are absent", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: 5 }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Credits")
  })

  it("clamps used requests to zero when usable_requests exceeds requests_plan", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(5, 200, 100))
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(2)
    const requestsLine = result.lines[0]
    expect(requestsLine.type).toBe("progress")
    expect(requestsLine.label).toBe("Requests")
    expect(requestsLine.used).toBe(0)
    expect(requestsLine.limit).toBe(100)
  })

  it("shows progress when usable_requests is negative", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue(makeSuccessResponse(5, -5, 500))
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(2)
    const requestsLine = result.lines[0]
    expect(requestsLine.type).toBe("progress")
    expect(requestsLine.label).toBe("Requests")
    expect(requestsLine.used).toBe(505)
    expect(requestsLine.limit).toBe(500)
  })

  it("throws when usable_requests is a string", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: 10, usable_requests: "50", requests_plan: 500 }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws when requests_plan is invalid", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: 10, usable_requests: 10, requests_plan: 0 }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("throws when credits is non-numeric", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ credits: "abc", usable_requests: 10, requests_plan: 500 }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "Usage response invalid. Try again later."
    )
  })

  it("omits credits line when credits field is missing", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockReturnValue("test-api-key")
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ usable_requests: 10, requests_plan: 500 }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Credits")).toBeUndefined()
    expect(result.lines[0].label).toBe("Requests")
  })
})
