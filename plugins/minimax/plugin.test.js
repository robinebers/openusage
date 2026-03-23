import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const PRIMARY_USAGE_URL = "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
const FALLBACK_USAGE_URL = "https://api.minimax.io/v1/coding_plan/remains"
const LEGACY_WWW_USAGE_URL = "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
const CN_PRIMARY_USAGE_URL = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"
const CN_FALLBACK_USAGE_URL = "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"
const CN_LEGACY_FALLBACK_USAGE_URL = "https://api.minimaxi.com/v1/coding_plan/remains"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function setEnv(ctx, envValues) {
  ctx.host.env.get.mockImplementation((name) =>
    Object.prototype.hasOwnProperty.call(envValues, name) ? envValues[name] : null
  )
}

function successPayload(overrides) {
  const base = {
    base_resp: { status_code: 0 },
    plan_name: "Plus",
    model_remains: [
      {
        model_name: "MiniMax-M2",
        current_interval_total_count: 300,
        current_interval_usage_count: 180,
        start_time: 1700000000000,
        end_time: 1700018000000,
      },
    ],
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

  it("prefers MINIMAX_CN_API_KEY in AUTO mode when both keys exist", async () => {
    const ctx = makeCtx()
    setEnv(ctx, {
      MINIMAX_CN_API_KEY: "cn-key",
      MINIMAX_API_KEY: "global-key",
    })
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

  it("uses MINIMAX_API_KEY when CN key is missing", async () => {
    const ctx = makeCtx()
    setEnv(ctx, {
      MINIMAX_API_KEY: "global-key",
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0][0]
    expect(call.url).toBe(PRIMARY_USAGE_URL)
    expect(call.headers.Authorization).toBe("Bearer global-key")
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
          bodyText: JSON.stringify(successPayload({
            plan_name: undefined,
            model_remains: [
              {
                model_name: "MiniMax-M2",
                current_interval_total_count: 1500, // CN Plus: 100 prompts × 15
                current_interval_usage_count: 1200, // Remaining
                start_time: 1700000000000,
                end_time: 1700018000000,
              },
            ],
          })),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].used).toBe(300)
    expect(result.lines[0].limit).toBe(1500)
    expect(result.lines[0].format.suffix).toBe("model-calls")
    expect(result.plan).toBeUndefined()
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

  it("parses usage, plan, reset timestamp, and period duration", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(successPayload()),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Plus (GLOBAL)")
    expect(result.lines.length).toBe(1)
    const line = result.lines[0]
    expect(line.label).toBe("Session")
    expect(line.type).toBe("progress")
    expect(line.used).toBe(120)
    expect(line.limit).toBe(300)
    expect(line.format.kind).toBe("count")
    expect(line.format.suffix).toBe("model-calls")
    expect(line.resetsAt).toBe("2023-11-15T03:13:20.000Z")
    expect(line.periodDurationMs).toBe(18000000)
  })

  it("treats current_interval_usage_count as remaining model-calls", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 1500,
            current_interval_usage_count: 1500,
            remains_time: 3600000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].used).toBe(0)
    expect(result.lines[0].limit).toBe(1500)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("infers Starter plan from 1500 model-call limit", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 1500,
            current_interval_usage_count: 1200,
            model_name: "MiniMax-M2",
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Starter (GLOBAL)")
    expect(result.lines[0].used).toBe(300)
    expect(result.lines[0].limit).toBe(1500)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("does not infer a GLOBAL plan from ambiguous 300 prompt limit", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 300,
            current_interval_usage_count: 120,
            model_name: "MiniMax-M2.5",
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines[0].used).toBe(180)
    expect(result.lines[0].limit).toBe(300)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("infers Ultra-High-Speed plan from 2000 prompt limit", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 2000,
            current_interval_usage_count: 1500,
            model_name: "MiniMax-M2.5-highspeed",
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Ultra-High-Speed (GLOBAL)")
    expect(result.lines[0].used).toBe(500)
    expect(result.lines[0].limit).toBe(2000)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("does not fallback to model name when plan cannot be inferred", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 1337,
            current_interval_usage_count: 1000,
            model_name: "MiniMax-M2.5",
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines[0].used).toBe(337)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("supports nested payload and remains_time reset fallback", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    vi.spyOn(Date, "now").mockReturnValue(1700000000000)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        data: {
          base_resp: { status_code: 0 },
          current_subscribe_title: "Max",
          model_remains: [
            {
              current_interval_total_count: 100,
              current_interval_usage_count: 40,
              remains_time: 7200,
            },
          ],
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]
    const expectedReset = new Date(1700000000000 + 7200 * 1000).toISOString()

    expect(result.plan).toBe("Max (GLOBAL)")
    expect(line.used).toBe(60)
    expect(line.limit).toBe(100)
    expect(line.format.suffix).toBe("model-calls")
    expect(line.resetsAt).toBe(expectedReset)
  })

  it("treats small remains_time values as milliseconds when seconds exceed window", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    vi.spyOn(Date, "now").mockReturnValue(1700000000000)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        data: {
          base_resp: { status_code: 0 },
          model_remains: [
            {
              current_interval_total_count: 100,
              current_interval_usage_count: 55,
              remains_time: 300000,
            },
          ],
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]

    expect(line.used).toBe(45)
    expect(line.limit).toBe(100)
    expect(line.format.suffix).toBe("model-calls")
    expect(line.resetsAt).toBe(new Date(1700000000000 + 300000).toISOString())
  })

  it("supports remaining-count payload variants", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan_name: "MiniMax Coding Plan Pro",
        model_remains: [
          {
            current_interval_total_count: 300,
            current_interval_remaining_count: 120,
            end_time: 1700018000000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]

    expect(result.plan).toBe("Pro (GLOBAL)")
    expect(line.used).toBe(180)
    expect(line.limit).toBe(300)
    expect(line.format.suffix).toBe("model-calls")
  })

  it("throws on HTTP auth status", async () => {
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

    expect(result.lines[0].used).toBe(120)
    expect(result.lines[0].format.suffix).toBe("model-calls")
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
          bodyText: JSON.stringify(successPayload({
            model_remains: [
              {
                model_name: "MiniMax-M2",
                current_interval_total_count: 1500, // CN Plus: 100 prompts × 15
                current_interval_usage_count: 1200, // Remaining
                start_time: 1700000000000,
                end_time: 1700018000000,
              },
            ],
          })),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].used).toBe(300)
    expect(result.lines[0].limit).toBe(1500)
    expect(result.lines[0].format.suffix).toBe("model-calls")
    expect(ctx.host.http.request.mock.calls.length).toBe(2)
    expect(ctx.host.http.request.mock.calls[0][0].url).toBe(CN_PRIMARY_USAGE_URL)
    expect(ctx.host.http.request.mock.calls[1][0].url).toBe(CN_FALLBACK_USAGE_URL)
  })

  it("infers CN Starter plan from 600 model-call limit", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(
        successPayload({
          plan_name: undefined, // Force inference
          model_remains: [
            {
              model_name: "MiniMax-M2",
              current_interval_total_count: 600, // 40 prompts × 15
              current_interval_usage_count: 500, // Remaining (not used!)
              start_time: 1700000000000,
              end_time: 1700018000000,
            },
          ],
        })
      ),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Starter (CN)")
    expect(result.lines[0].limit).toBe(600)
    expect(result.lines[0].used).toBe(100)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("keeps raw CN session counts when explicit plan metadata is present", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan_name: "Plus",
        model_remains: [
          {
            model_name: "MiniMax-M2.5",
            current_interval_total_count: 100,
            current_interval_usage_count: 70,
            start_time: 1700000000000,
            end_time: 1700018000000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Plus (CN)")
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0].label).toBe("Session")
    expect(result.lines[0].limit).toBe(100)
    expect(result.lines[0].used).toBe(30)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("shows extra CN token-plan resource lines for Text to Speech HD and image-01", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        data: {
          base_resp: { status_code: 0 },
          current_subscribe_title: "Plus",
          model_remains: [
            {
              model_name: "MiniMax-M2.5",
              current_interval_total_count: 100,
              current_interval_usage_count: 70,
              start_time: 1700000000000,
              end_time: 1700018000000,
            },
            {
              model_name: "Text to Speech HD",
              current_interval_total_count: 2500000,
              current_interval_usage_count: 2000000,
              start_time: 1700000000000,
              end_time: 1700086400000,
            },
            {
              model_name: "image-01",
              current_interval_total_count: 1000,
              current_interval_usage_count: 900,
              start_time: 1700000000000,
              end_time: 1700086400000,
            },
          ],
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Plus (CN)")
    expect(result.lines).toHaveLength(3)
    expect(result.lines[0]).toMatchObject({
      label: "Session",
      used: 30,
      limit: 100,
      format: { kind: "count", suffix: "model-calls" },
    })
    expect(result.lines[1]).toMatchObject({
      label: "Text to Speech HD",
      used: 500000,
      limit: 2500000,
      format: { kind: "count", suffix: "chars" },
    })
    expect(result.lines[2]).toMatchObject({
      label: "image-01",
      used: 100,
      limit: 1000,
      format: { kind: "count", suffix: "images" },
    })
  })

  it("does not infer an ambiguous CN plan from 1500 model-call limit", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(
        successPayload({
          plan_name: undefined, // Force inference
          model_remains: [
            {
              model_name: "MiniMax-M2",
              current_interval_total_count: 1500, // 100 prompts × 15
              current_interval_usage_count: 1200, // Remaining
              start_time: 1700000000000,
              end_time: 1700018000000,
            },
          ],
        })
      ),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines[0].limit).toBe(1500)
    expect(result.lines[0].used).toBe(300)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("does not infer an ambiguous CN plan from 4500 model-call limit", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(
        successPayload({
          plan_name: undefined, // Force inference
          model_remains: [
            {
              model_name: "MiniMax-M2",
              current_interval_total_count: 4500, // 300 prompts × 15
              current_interval_usage_count: 2700, // Remaining
              start_time: 1700000000000,
              end_time: 1700018000000,
            },
          ],
        })
      ),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines[0].limit).toBe(4500)
    expect(result.lines[0].used).toBe(1800)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("normalizes CN explicit high-speed plan labels to the shared six-plan naming", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        data: {
          base_resp: { status_code: 0 },
          current_subscribe_title: "Plus-极速版",
          model_remains: [
            {
              model_name: "MiniMax-M2.5-highspeed",
              current_interval_total_count: 1500,
              current_interval_usage_count: 1200,
              start_time: 1700000000000,
              end_time: 1700018000000,
            },
          ],
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Plus-High-Speed (CN)")
    expect(result.lines[0].limit).toBe(1500)
    expect(result.lines[0].used).toBe(300)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("does not infer CN plan for unknown CN model-call limits", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_CN_API_KEY: "cn-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify(
        successPayload({
          plan_name: undefined, // Force inference
          model_remains: [
            {
              model_name: "MiniMax-M2",
              current_interval_total_count: 9000, // Unknown CN tier
              current_interval_usage_count: 6000, // Remaining
              start_time: 1700000000000,
              end_time: 1700018000000,
            },
          ],
        })
      ),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines[0].limit).toBe(9000)
    expect(result.lines[0].used).toBe(3000)
    expect(result.lines[0].format.suffix).toBe("model-calls")
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

    expect(result.lines[0].used).toBe(120)
    expect(result.lines[0].format.suffix).toBe("model-calls")
    expect(ctx.host.http.request.mock.calls.length).toBe(2)
  })

  it("throws when API returns non-zero base_resp status", async () => {
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
    expect(result.lines[0].used).toBe(120)
    expect(result.lines[0].limit).toBe(300)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("supports camelCase modelRemains and explicit used count fields", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    vi.spyOn(Date, "now").mockReturnValue(1700000000000)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        modelRemains: [
          null,
          {
            currentIntervalTotalCount: "500",
            currentIntervalUsedCount: "123",
            remainsTime: 7200000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]
    expect(line.resetsAt).toBe(new Date(1700000000000 + 7200000).toISOString())
    expect(line.periodDurationMs).toBeUndefined()
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

  it("normalizes bare 'MiniMax Coding Plan' to 'Coding Plan'", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan_name: "MiniMax Coding Plan",
        model_remains: [
          {
            current_interval_total_count: 100,
            current_interval_usage_count: 20,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Coding Plan (GLOBAL)")
  })

  it("supports payload.modelRemains and remains-count aliases", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        plan: "MiniMax Coding Plan: Team",
        modelRemains: [
          {
            currentIntervalTotalCount: "300",
            remainsCount: "120",
            endTime: 1700018000000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Team (GLOBAL)")
    expect(result.lines[0].used).toBe(180)
    expect(result.lines[0].limit).toBe(300)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("clamps negative used counts to zero", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 100,
            current_interval_used_count: -5,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].used).toBe(0)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("clamps used counts above total", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 100,
            current_interval_used_count: 500,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].used).toBe(100)
    expect(result.lines[0].format.suffix).toBe("model-calls")
  })

  it("supports epoch seconds for start/end timestamps", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [
          {
            current_interval_total_count: 100,
            current_interval_usage_count: 25,
            start_time: 1700000000,
            end_time: 1700018000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]
    expect(line.periodDurationMs).toBe(18000000)
    expect(line.resetsAt).toBe(new Date(1700018000 * 1000).toISOString())
  })

  it("infers remains_time as milliseconds when value is plausible", async () => {
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
            current_interval_total_count: 100,
            current_interval_usage_count: 40,
            remains_time: 300000,
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].resetsAt).toBe(new Date(1700000000000 + 300000).toISOString())
  })

  it("throws parse error when model_remains entries are unusable", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [null, { current_interval_total_count: 0, current_interval_usage_count: 1 }],
      }),
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })

  it("throws parse error when both used and remaining counts are missing", async () => {
    const ctx = makeCtx()
    setEnv(ctx, { MINIMAX_API_KEY: "mini-key" })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        base_resp: { status_code: 0 },
        model_remains: [{ current_interval_total_count: 100 }],
      }),
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data")
  })
})
