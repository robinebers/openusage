import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const PRIMARY_USAGE_URL = "https://api.minimax.io/v1/token_plan/remains"
const FALLBACK_USAGE_URL = "https://www.minimax.io/v1/token_plan/remains"
const LEGACY_WWW_USAGE_URL = "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
const CN_PRIMARY_USAGE_URL = "https://api.minimaxi.com/v1/token_plan/remains"
const CN_FALLBACK_USAGE_URL = "https://www.minimaxi.com/v1/token_plan/remains"
const CN_LEGACY_FALLBACK_USAGE_URL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function setEnv(ctx, envValues) {
  ctx.host.env.get.mockImplementation((name) =>
    Object.prototype.hasOwnProperty.call(envValues, name) ? envValues[name] : null
  )
}

// Models the live Token Plan remains response: a "general" bucket carrying both a
// rolling 5-hour interval and a weekly window, each with a remaining-percent field.
function generalBucket(overrides) {
  return Object.assign(
    {
      model_name: "general",
      current_interval_total_count: 0,
      current_interval_usage_count: 0,
      current_interval_remaining_percent: 100,
      start_time: 1700000000000,
      end_time: 1700018000000,
      remains_time: 15994987,
      current_weekly_total_count: 0,
      current_weekly_usage_count: 0,
      current_weekly_remaining_percent: 100,
      weekly_start_time: 1700000000000,
      weekly_end_time: 1700604800000,
      weekly_remains_time: 498394987,
    },
    overrides || {}
  )
}

function videoBucket(overrides) {
  return Object.assign(
    {
      model_name: "video",
      current_interval_total_count: 0,
      current_interval_usage_count: 0,
      current_interval_remaining_percent: 100,
      start_time: 1700000000000,
      end_time: 1700086400000,
      current_weekly_total_count: 0,
      current_weekly_usage_count: 0,
      current_weekly_remaining_percent: 100,
      weekly_start_time: 1700000000000,
      weekly_end_time: 1700604800000,
    },
    overrides || {}
  )
}

function successPayload(overrides) {
  const base = {
    base_resp: { status_code: 0 },
    plan_name: "Plus",
    model_remains: [generalBucket()],
  }
  if (!overrides) return base
  return Object.assign(base, overrides)
}

describe("minimax plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("throws when API key is missing", async () => {
    const ctx = makeCtx()
    setEnv(ctx, {})
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(
      "MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY."
    )
  })

  it("uses MINIMAX_API_KEY for auth header", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.url).toBe(PRIMARY_USAGE_URL)
    expect(call.headers.Authorization).toBe("Bearer mini-key")
    expect(call.headers["Content-Type"]).toBe("application/json")
    expect(call.headers.Accept).toBe("application/json")
  })

  it("falls back to MINIMAX_API_TOKEN", async () => {
    const ctx = makeCtx()
    setEnv(ctx, {
      MINIMAX_API_KEY: "",
      MINIMAX_API_TOKEN: "token-fallback",
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.headers.Authorization).toBe("Bearer token-fallback")
  })

  it("auto-selects CN endpoint when MINIMAX_CN_API_KEY exists", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key", MINIMAX_API_KEY: "global-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.url).toBe(CN_PRIMARY_USAGE_URL)
    expect(call.headers.Authorization).toBe("Bearer cn-key")
    expect(result.plan).toBe("Plus (CN)")
  })

  it("uses GLOBAL first in AUTO mode when CN key is missing", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "global-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.url).toBe(PRIMARY_USAGE_URL)
  })

  it("falls back to CN in AUTO mode when GLOBAL auth fails", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "global-key" })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === PRIMARY_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === FALLBACK_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === LEGACY_WWW_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === CN_PRIMARY_USAGE_URL) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify(successPayload()),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Plus (CN)")
    const first = ctx.host.http.request.mock.calls[0][0].url
    const last = ctx.host.http.request.mock.calls[ctx.host.http.request.mock.calls.length - 1][0].url
    expect(first).toBe(PRIMARY_USAGE_URL)
    expect(last).toBe(CN_PRIMARY_USAGE_URL)
  })

  it("preserves first non-auth error in AUTO mode when later CN retry is auth", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "global-key" })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === PRIMARY_USAGE_URL) return { status: 500, headers: {}, bodyText: "{}" }
      if (req.url === FALLBACK_USAGE_URL) return { status: 500, headers: {}, bodyText: "{}" }
      if (req.url === LEGACY_WWW_USAGE_URL) return { status: 500, headers: {}, bodyText: "{}" }
      if (req.url === CN_PRIMARY_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === CN_FALLBACK_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === CN_LEGACY_FALLBACK_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed (HTTP 500)")
  })

  it("preserves first auth error in AUTO mode when later CN retry is non-auth", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "global-key" })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === PRIMARY_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === FALLBACK_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === LEGACY_WWW_USAGE_URL) return { status: 401, headers: {}, bodyText: "" }
      if (req.url === CN_PRIMARY_USAGE_URL) return { status: 500, headers: {}, bodyText: "{}" }
      if (req.url === CN_FALLBACK_USAGE_URL) return { status: 500, headers: {}, bodyText: "{}" }
      if (req.url === CN_LEGACY_FALLBACK_USAGE_URL) return { status: 500, headers: {}, bodyText: "{}" }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired. Check your MiniMax API key.")
  })

  it("renders Session + Weekly from the general bucket remaining percentages", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan_name: "Max",
        model_remains: [
          generalBucket({
            current_interval_remaining_percent: 60,
            current_weekly_remaining_percent: 85,
          }),
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Max (GLOBAL)")
    expect(result.lines).toHaveLength(2)
    expect(result.lines[0]).toMatchObject({
      label: "Session",
      used: 40,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: "2023-11-15T03:13:20.000Z",
      periodDurationMs: 18000000,
    })
    expect(result.lines[1]).toMatchObject({
      label: "Weekly",
      used: 15,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: new Date(1700604800000).toISOString(),
      periodDurationMs: 604800000,
    })
  })

  it("renders Video interval and weekly lines after the general bucket", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          generalBucket({
            current_interval_remaining_percent: 70,
            current_weekly_remaining_percent: 90,
          }),
          videoBucket({
            current_interval_remaining_percent: 100,
            current_weekly_remaining_percent: 100,
          }),
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.map((line) => line.label)).toEqual([
      "Session",
      "Weekly",
      "Video",
      "Video (Weekly)",
    ])
    expect(result.lines[0]).toMatchObject({ label: "Session", used: 30, limit: 100 })
    expect(result.lines[2]).toMatchObject({ label: "Video", used: 0, format: { kind: "percent" } })
    expect(result.lines[3]).toMatchObject({ label: "Video (Weekly)", used: 0 })
  })

  it("title-cases unknown model_name buckets for their lines", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          generalBucket({ current_interval_remaining_percent: 80 }),
          {
            model_name: "music_generation",
            current_interval_remaining_percent: 50,
            start_time: 1700000000000,
            end_time: 1700018000000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const musicLine = result.lines.find((line) => line.label === "Music Generation")
    expect(musicLine).toBeDefined()
    expect(musicLine.used).toBe(50)
    expect(musicLine.format.kind).toBe("percent")
  })

  it("falls back to a generic Token Plan label when no tier can be determined", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [generalBucket({ current_interval_remaining_percent: 25 })],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Token Plan (CN)")
    expect(result.lines[0]).toMatchObject({ label: "Session", used: 75 })
  })

  it("surfaces the MINIMAX_PLAN override when the API exposes no tier", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key", MINIMAX_PLAN: "plus" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [generalBucket({ current_interval_remaining_percent: 25 })],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Plus (CN)")
  })

  it("prefers an explicit API plan field over the MINIMAX_PLAN override", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key", MINIMAX_PLAN: "ultra" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan_name: "Max",
        model_remains: [generalBucket({ current_interval_remaining_percent: 25 })],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Max (CN)")
  })

  it("falls back to count math and tier inference when percent is absent", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            model_name: "general",
            current_interval_total_count: 1500,
            current_interval_usage_count: 1200,
            start_time: 1700000000000,
            end_time: 1700018000000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    // 1500 maps to Starter on GLOBAL; usage_count is the remaining count.
    expect(result.plan).toBe("Starter (GLOBAL)")
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0]).toMatchObject({
      label: "Session",
      used: 20,
      limit: 100,
      format: { kind: "percent" },
    })
  })

  it("normalizes explicit Ultra plan titles", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        data: {
          base_resp: { status_code: 0 },
          current_subscribe_title: "Ultra",
          model_remains: [generalBucket({ current_interval_remaining_percent: 40 })],
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Ultra (CN)")
    expect(result.lines[0]).toMatchObject({ label: "Session", used: 60 })
  })

  it("normalizes bare 'MiniMax Coding Plan' to 'Token Plan'", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan_name: "MiniMax Coding Plan",
        model_remains: [generalBucket({ current_interval_remaining_percent: 80 })],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Token Plan (GLOBAL)")
  })

  it("derives reset from remains_time when end_time is absent", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    vi.spyOn(Date, "now").mockReturnValue(1700000000000)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            model_name: "general",
            current_interval_remaining_percent: 40,
            remains_time: 7200,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]

    expect(line.used).toBe(60)
    expect(line.resetsAt).toBe(new Date(1700000000000 + 7200 * 1000).toISOString())
    expect(line.periodDurationMs).toBeUndefined()
  })

  it("supports camelCase modelRemains and epoch-seconds timestamps", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        modelRemains: [
          null,
          {
            modelName: "general",
            current_interval_remaining_percent: 30,
            start_time: 1700000000,
            end_time: 1700018000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]
    expect(line.label).toBe("Session")
    expect(line.used).toBe(70)
    expect(line.periodDurationMs).toBe(18000000)
    expect(line.resetsAt).toBe(new Date(1700018000 * 1000).toISOString())
  })

  it("clamps remaining percent outside 0-100 into used bounds", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          generalBucket({
            current_interval_remaining_percent: 120,
            current_weekly_remaining_percent: -5,
          }),
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].used).toBe(0)
    expect(result.lines[1].used).toBe(100)
  })

  it("falls back to secondary endpoint when primary fails", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === PRIMARY_USAGE_URL) return { status: 503, headers: {}, bodyText: "{}" }
      if (req.url === FALLBACK_USAGE_URL) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify(successPayload()),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].label).toBe("Session")
    expect(ctx.host.http.request.mock.calls.length).toBe(2)
  })

  it("uses CN fallback endpoint when CN primary fails", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === CN_PRIMARY_USAGE_URL) return { status: 503, headers: {}, bodyText: "{}" }
      if (req.url === CN_FALLBACK_USAGE_URL) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify(successPayload()),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].label).toBe("Session")
    expect(ctx.host.http.request.mock.calls.length).toBe(2)
    expect(ctx.host.http.request.mock.calls[0][0].url).toBe(CN_PRIMARY_USAGE_URL)
    expect(ctx.host.http.request.mock.calls[1][0].url).toBe(CN_FALLBACK_USAGE_URL)
  })

  it("falls back when primary returns auth-like status", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === PRIMARY_USAGE_URL) return { status: 403, headers: {}, bodyText: "<html>cf</html>" }
      if (req.url === FALLBACK_USAGE_URL) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify(successPayload()),
        }
      }
      if (req.url === LEGACY_WWW_USAGE_URL) return { status: 403, headers: {}, bodyText: "<html>cf</html>" }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].label).toBe("Session")
    expect(ctx.host.http.request.mock.calls.length).toBe(2)
  })

  it("throws on HTTP auth status after exhausting all endpoints", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" })
    const plugin = await loadPlugin()
    let message = ""
    try {
      plugin.probe(ctx)
    } catch (e) {
      message = String(e)
    }
    expect(message).toContain("Session expired")
    expect(ctx.host.http.request.mock.calls.length).toBe(6)
  })

  it("throws when API returns non-zero base_resp status (cookie missing)", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 1004, status_msg: "cookie is missing, log in again" },
        model_remains: [],
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("uses same generic auth error text for CN path", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired. Check your MiniMax API key.")
  })

  it("throws generic MiniMax API error when status message is absent", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 429 },
        model_remains: [],
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("MiniMax API error (status 429)")
  })

  it("throws when payload has no usable usage data", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({ base_resp: { status_code: 0 }, model_remains: [] }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })

  it("throws when buckets carry neither percent nor counts", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [null, { model_name: "general", current_interval_total_count: 0 }],
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })

  it("throws HTTP error when all endpoints return non-2xx", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({ status: 500, headers: {}, bodyText: "{}" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed (HTTP 500)")
  })

  it("throws network error when all endpoints fail with exceptions", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("ECONNRESET")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed. Check your connection.")
  })

  it("throws parse error when all endpoints return invalid JSON with 2xx status", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({ status: 200, headers: {}, bodyText: "not-json" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data.")
  })

  it("continues when env getter throws and still uses fallback env var", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "MINIMAX_API_KEY") throw new Error("env unavailable")
      if (name === "MINIMAX_API_TOKEN") return "fallback-token"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Session")
  })

  it("falls back to GLOBAL when MINIMAX_CN_API_KEY lookup throws in AUTO mode", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "MINIMAX_CN_API_KEY") throw new Error("cn env unavailable")
      if (name === "MINIMAX_API_KEY") return "global-key"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(ctx.host.http.request.mock.calls[0][0].url).toBe(PRIMARY_USAGE_URL)
    expect(result.plan).toBe("Plus (GLOBAL)")
  })
})
