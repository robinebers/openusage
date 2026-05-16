import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

describe("warp plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws and logs info if defaults key is not found", async () => {
    const ctx = makeCtx()
    ctx.host.defaults.read.mockImplementation(() => {
      throw new Error("key not found")
    })
    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow(
      "No Warp AI usage data found. Ensure Warp is installed and you have used AI at least once. If you have, this may be a plugin bug."
    )
    expect(ctx.host.log.info).toHaveBeenCalledWith(
      expect.stringContaining("Warp: AIRequestLimitInfo key not found in preferences")
    )
  })

  it("throws and logs error if JSON is malformed or not an object", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()

    const malformedInputs = [
      "invalid json",
      "null",
      "42",
      "true",
      "",
    ]

    for (const input of malformedInputs) {
      ctx.host.defaults.read.mockReturnValue(input)
      expect(() => plugin.probe(ctx)).toThrow("Warp AI quota data is malformed. This may be a plugin bug.")
      expect(ctx.host.log.error).toHaveBeenCalledWith(
        expect.stringContaining("Warp: Malformed quota data")
      )
      vi.clearAllMocks()
    }
  })

  it("throws and logs error if quota data fields are invalid or missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()

    const invalidPayloads = [
      {}, // empty object
      [], // array
      { limit: 100, next_refresh_time: "2026-06-01T00:00:00Z" }, // missing used
      { num_requests_used_since_refresh: 10, next_refresh_time: "2026-06-01T00:00:00Z" }, // missing limit
      { num_requests_used_since_refresh: 10, limit: 100 }, // missing resetsAt
      { num_requests_used_since_refresh: "10", limit: 100, next_refresh_time: "2026-06-01T00:00:00Z" }, // used is string
      { num_requests_used_since_refresh: 10, limit: "100", next_refresh_time: "2026-06-01T00:00:00Z" }, // limit is string
      { num_requests_used_since_refresh: 10, limit: 0, next_refresh_time: "2026-06-01T00:00:00Z" }, // limit is 0
      { num_requests_used_since_refresh: 10, limit: -5, next_refresh_time: "2026-06-01T00:00:00Z" }, // limit is negative
      { num_requests_used_since_refresh: 10, limit: 100, next_refresh_time: "" }, // resetsAt is empty string
      { num_requests_used_since_refresh: 10, limit: 100, next_refresh_time: "not-a-date" }, // resetsAt is invalid date string
      { num_requests_used_since_refresh: NaN, limit: 100, next_refresh_time: "2026-06-01T00:00:00Z" }, // used is NaN
      { num_requests_used_since_refresh: 10, limit: NaN, next_refresh_time: "2026-06-01T00:00:00Z" }, // limit is NaN
      { num_requests_used_since_refresh: Infinity, limit: 100, next_refresh_time: "2026-06-01T00:00:00Z" }, // used is Infinity
      { num_requests_used_since_refresh: 10, limit: Infinity, next_refresh_time: "2026-06-01T00:00:00Z" }, // limit is Infinity
    ]

    for (const payload of invalidPayloads) {
      const json = JSON.stringify(payload)
      ctx.host.defaults.read.mockReturnValue(json)
      expect(() => plugin.probe(ctx)).toThrow("Warp AI quota data is malformed. This may be a plugin bug.")
      expect(ctx.host.log.error).toHaveBeenCalledWith(
        expect.stringContaining("Warp: Incomplete quota data")
      )
      vi.clearAllMocks()
    }
  })

  it("throws and logs info if data is stale", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2026-05-20T12:00:00Z"
    const resetsAt = "2026-05-19T00:00:00Z"
    ctx.host.defaults.read.mockReturnValue(
      JSON.stringify({
        num_requests_used_since_refresh: 10,
        limit: 100,
        next_refresh_time: resetsAt,
      })
    )
    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("No active Warp AI quota found. Have your credits reset recently?")
    expect(ctx.host.log.info).toHaveBeenCalledWith(
      expect.stringContaining("Warp: Quota data is stale")
    )
  })

  it("parses valid credits data", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2026-05-20T12:00:00Z"
    ctx.host.defaults.read.mockReturnValue(
      JSON.stringify({
        num_requests_used_since_refresh: 42,
        limit: 100,
        next_refresh_time: "2026-06-01T00:00:00Z",
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(ctx.host.defaults.read).toHaveBeenCalledWith("dev.warp.Warp-Stable", "AIRequestLimitInfo")
    expect(result.lines).toHaveLength(1)

    const credits = result.lines.find((l) => l.label === "AI Credits")
    expect(credits.used).toBe(42)
    expect(credits.limit).toBe(100)
    expect(credits.resetsAt).toBe("2026-06-01T00:00:00.000Z")
  })
})
