import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const PRIMARY_CACHE_DB_PATH =
  "~/Library/Containers/ai.perplexity.mac/Data/Library/Caches/ai.perplexity.mac/Cache.db"
const FALLBACK_CACHE_DB_PATH = "~/Library/Caches/ai.perplexity.mac/Cache.db"

const GROUP_ID = "test-group-id"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeJwtLikeToken() {
  return "eyJ" + "a".repeat(80) + "." + "b".repeat(80) + "." + "c".repeat(80)
}

function makeRequestHexWithBearer(token, extraBytes) {
  const base = Buffer.from("Bearer " + token, "utf8")
  const out = extraBytes ? Buffer.concat([base, extraBytes]) : base
  return out.toString("hex").toUpperCase()
}

function makeRequestHexWithSessionFields(token, userAgent, deviceId) {
  const chunks = [Buffer.from("Bearer " + token + " ", "utf8")]
  if (userAgent) {
    chunks.push(Buffer.from(userAgent, "utf8"))
    chunks.push(Buffer.from([0x00]))
  }
  if (deviceId) {
    chunks.push(Buffer.from(deviceId, "utf8"))
    chunks.push(Buffer.from([0x00]))
  }
  return Buffer.concat(chunks).toString("hex").toUpperCase()
}

function mockCacheSession(ctx, options = {}) {
  const selectedDbPath = options.dbPath || PRIMARY_CACHE_DB_PATH
  const requestHex = options.requestHex || null

  const originalExists = ctx.host.fs.exists
  ctx.host.fs.exists = (path) => path === selectedDbPath || originalExists(path)

  ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
    if (dbPath === selectedDbPath && String(sql).includes("https://www.perplexity.ai/api/user")) {
      return JSON.stringify([{ requestHex }])
    }
    return "[]"
  })
}

function mockRestApi(ctx, options = {}) {
  const balance = options.balance ?? 4.99
  const isPro = options.isPro ?? true
  const customerInfo = options.customerInfo ?? { balance, is_pro: isPro }
  const usageAnalytics = options.usageAnalytics ?? [
    { meter_event_summaries: [{ usage: 1, cost: 0.04 }] },
  ]
  const rateLimits = options.rateLimits ?? null

  ctx.host.http.request.mockImplementation((req) => {
    if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify({ orgs: [{ api_org_id: GROUP_ID, is_default_org: true }] }),
      }
    }

    if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}`) {
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify({ customerInfo }),
      }
    }

    if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify(usageAnalytics),
      }
    }

    if (req.url === "https://www.perplexity.ai/rest/rate-limit/all" && rateLimits) {
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify(rateLimits),
      }
    }

    return { status: 404, headers: {}, bodyText: "{}" }
  })
}

describe("perplexity plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("throws when no local session is available", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("returns only an API credits progress bar (primary cache path)", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { dbPath: PRIMARY_CACHE_DB_PATH, requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, { balance: 4.99, usageAnalytics: [{ meter_event_summaries: [{ cost: 0.04 }] }] })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(Array.isArray(result.lines)).toBe(true)
    expect(result.lines.length).toBe(1)

    const line = result.lines[0]
    expect(line.type).toBe("progress")
    expect(line.label).toBe("API credits")
    expect(line.format.kind).toBe("dollars")
    expect(line.used).toBe(0.04)
    expect(line.limit).toBe(4.99) // limit = balance only
    expect(line.resetsAt).toBeUndefined()
    expect(line.periodDurationMs).toBeUndefined()
  })

  it("falls back to secondary cache path", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { dbPath: FALLBACK_CACHE_DB_PATH, requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, { balance: 10, isPro: false, usageAnalytics: [{ meter_event_summaries: [{ cost: 0 }] }] })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("API credits")
    expect(result.lines[0].limit).toBe(10)
  })

  it("does not read env", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)
    expect(ctx.host.env.get).not.toHaveBeenCalled()
  })

  it("treats cache row without bearer token as not logged in", async () => {
    const ctx = makeCtx()
    mockCacheSession(ctx, { requestHex: "00DEADBEEF00" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("strips trailing bplist marker after bearer token", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    const markerBytes = Buffer.from([0x5f, 0x10, 0xb5]) // '_' then bplist int marker
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token, markerBytes) })
    mockRestApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const call = ctx.host.http.request.mock.calls[0]?.[0]
    expect(call.headers.Authorization).toBe("Bearer " + token)
  })

  it("throws usage data unavailable when balance exists but usage analytics fails", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ orgs: [{ api_org_id: GROUP_ID, is_default_org: true }] }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ customerInfo: { balance: 4.99, is_pro: false } }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
        return { status: 403, headers: {}, bodyText: "<html>Just a moment...</html>" }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage data unavailable")
  })

  it("returns $0 used when usage analytics has empty meter_event_summaries", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      balance: 5.0,
      usageAnalytics: [
        { id: "mtr_1", meter_event_summaries: [] },
        { id: "mtr_2", meter_event_summaries: [] },
      ],
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(1)
    expect(result.lines[0].used).toBe(0)
    expect(result.lines[0].limit).toBe(5.0)
  })

  it("returns $0 used when usage analytics is an empty array", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      balance: 5.0,
      usageAnalytics: [],
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("API credits")
    expect(result.lines[0].used).toBe(0)
    expect(result.lines[0].limit).toBe(5.0)
  })

  it("supports trailing-slash REST fallbacks and nested money fields", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return { status: 404, headers: {}, bodyText: "{}" }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ data: [{ id: 123, isDefaultOrg: true }] }),
        }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/123") {
        return { status: 503, headers: {}, bodyText: "{}" }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/123/") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({
            customerInfo: { is_pro: false },
            organization: { balance: { amount_cents: 250 } },
          }),
        }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/123/usage-analytics") {
        return { status: 502, headers: {}, bodyText: "{}" }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/123/usage-analytics/") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ meterEventSummaries: [{ cost: 0.25 }] }]),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBeUndefined()
    expect(result.lines[0].label).toBe("API credits")
    expect(result.lines[0].used).toBe(0.25)
    expect(result.lines[0].limit).toBe(2.5)
  })

  it("extracts app version and device id from cached request and forwards as headers", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, {
      requestHex: makeRequestHexWithSessionFields(token, "Ask/9.9.9", "macos:device-123"),
    })
    mockRestApi(ctx)

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const firstRestCall = ctx.host.http.request.mock.calls.find((call) =>
      String(call[0]?.url).includes("/rest/pplx-api/v2/groups")
    )?.[0]

    expect(firstRestCall).toBeTruthy()
    expect(firstRestCall.headers["X-App-Version"]).toBe("9.9.9")
    expect(firstRestCall.headers["X-Device-ID"]).toBe("macos:device-123")
    expect(firstRestCall.headers["User-Agent"]).toBe("Ask/9.9.9")
  })

  it("throws when groups request is unauthorized", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Unable to connect")
  })

  it("throws usage data unavailable when analytics payload has no numeric cost", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ orgs: [{ api_org_id: GROUP_ID, is_default_org: true }] }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ customerInfo: { balance: "$4.99", is_pro: false } }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ meter_event_summaries: [{ cost: "NaN" }] }]),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage data unavailable")
  })

  it("recovers when primary cache sqlite read fails and fallback cache is valid", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    const requestHex = makeRequestHexWithBearer(token)
    const originalExists = ctx.host.fs.exists

    ctx.host.fs.exists = (path) =>
      path === PRIMARY_CACHE_DB_PATH || path === FALLBACK_CACHE_DB_PATH || originalExists(path)

    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (!String(sql).includes("https://www.perplexity.ai/api/user")) return "[]"
      if (dbPath === PRIMARY_CACHE_DB_PATH) throw new Error("primary db locked")
      if (dbPath === FALLBACK_CACHE_DB_PATH) return JSON.stringify([{ requestHex }])
      return "[]"
    })
    mockRestApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].label).toBe("API credits")
  })

  it("continues when primary cache exists-check throws and fallback has a session", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    const requestHex = makeRequestHexWithBearer(token)
    const originalExists = ctx.host.fs.exists

    ctx.host.fs.exists = (path) => {
      if (path === PRIMARY_CACHE_DB_PATH) throw new Error("permission denied")
      if (path === FALLBACK_CACHE_DB_PATH) return true
      return originalExists(path)
    }
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (dbPath === FALLBACK_CACHE_DB_PATH && String(sql).includes("https://www.perplexity.ai/api/user")) {
        return JSON.stringify([{ requestHex }])
      }
      return "[]"
    })
    mockRestApi(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].label).toBe("API credits")
  })

  it("parses balance from regex-matched credit key path", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ orgs: [{ api_org_id: GROUP_ID, is_default_org: true }] }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({
            customerInfo: { is_pro: true },
            available_credit: "$7.25",
          }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ meter_event_summaries: [{ cost: 0.25 }] }]),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Pro")
    expect(result.lines[0].limit).toBe(7.25)
  })

  it("uses first group id when groups payload is an array without default flag", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ id: "grp-a" }, { id: "grp-b" }]),
        }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/grp-a") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([
            { note: "first element has no balance" },
            { balance_usd: 6.5, customerInfo: { is_pro: false } },
          ]),
        }
      }
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups/grp-a/usage-analytics") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ meter_event_summaries: [{ cost: 0.5 }] }]),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].limit).toBe(6.5)
    expect(result.lines[0].used).toBe(0.5)
  })

  it("throws when groups payload contains no readable ids", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return { status: 200, headers: {}, bodyText: JSON.stringify({ orgs: [{ name: "missing-id" }] }) }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Unable to connect")
  })

  it("treats empty cache query rows as not logged in", async () => {
    const ctx = makeCtx()
    const originalExists = ctx.host.fs.exists
    ctx.host.fs.exists = (path) => path === PRIMARY_CACHE_DB_PATH || originalExists(path)
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (dbPath === PRIMARY_CACHE_DB_PATH && String(sql).includes("https://www.perplexity.ai/api/user")) {
        return JSON.stringify([])
      }
      return "[]"
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("treats cache rows without requestHex as not logged in", async () => {
    const ctx = makeCtx()
    const originalExists = ctx.host.fs.exists
    ctx.host.fs.exists = (path) => path === PRIMARY_CACHE_DB_PATH || originalExists(path)
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (dbPath === PRIMARY_CACHE_DB_PATH && String(sql).includes("https://www.perplexity.ai/api/user")) {
        return JSON.stringify([{}])
      }
      return "[]"
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("treats non-string requestHex as not logged in", async () => {
    const ctx = makeCtx()
    const originalExists = ctx.host.fs.exists
    ctx.host.fs.exists = (path) => path === PRIMARY_CACHE_DB_PATH || originalExists(path)
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (dbPath === PRIMARY_CACHE_DB_PATH && String(sql).includes("https://www.perplexity.ai/api/user")) {
        return JSON.stringify([{ requestHex: 12345 }])
      }
      return "[]"
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("rejects malformed bearer token payloads from cache rows", async () => {
    const ctx = makeCtx()
    // Contains "Bearer " prefix but token has no JWT dots and invalid hex bytes later.
    const malformed = "426561726572204142435A5A"
    mockCacheSession(ctx, { requestHex: malformed })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when groups endpoint returns invalid JSON", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return { status: 200, headers: {}, bodyText: "not-json" }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Unable to connect")
  })

  it("throws balance unavailable when balance object only contains non-finite cents", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ orgs: [{ api_org_id: GROUP_ID, is_default_org: true }] }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({
            customerInfo: { is_pro: false },
            wallet: { amount_cents: "1e309" },
          }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ meter_event_summaries: [{ cost: 1.0 }] }]),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Balance unavailable")
  })

  it("throws rate limits unavailable when Pro subscriber has zero balance and no rate limits", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })

    ctx.host.http.request.mockImplementation((req) => {
      if (req.url === "https://www.perplexity.ai/rest/pplx-api/v2/groups") {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ orgs: [{ api_org_id: GROUP_ID, is_default_org: true }] }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({ customerInfo: { is_pro: true, balance: 0 } }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify([{ meter_event_summaries: [{ cost: 0.1 }] }]),
        }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Rate limits unavailable")
  })

  it("shows rate-limit text lines for Pro subscriber with zero balance", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, balance: 0 },
      usageAnalytics: [{ meter_event_summaries: [] }],
      rateLimits: { remaining_pro: 198, remaining_research: 20, remaining_labs: 25 },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(result.lines.length).toBe(3)
    expect(result.lines[0].type).toBe("text")
    expect(result.lines[0].label).toBe("Queries")
    expect(result.lines[0].value).toBe("198 remaining")
    expect(result.lines[1].label).toBe("Deep Research")
    expect(result.lines[1].value).toBe("20 remaining")
    expect(result.lines[2].label).toBe("Labs")
    expect(result.lines[2].value).toBe("25 remaining")
  })

  it("detects Max plan from is_max field", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, is_max: true, balance: 0 },
      usageAnalytics: [{ meter_event_summaries: [] }],
      rateLimits: { remaining_pro: 500 },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Max")
    expect(result.lines[0].label).toBe("Queries")
    expect(result.lines[0].value).toBe("500 remaining")
  })

  it("detects Max plan from subscription_tier field", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, subscription_tier: "max", balance: 0 },
      usageAnalytics: [{ meter_event_summaries: [] }],
      rateLimits: { remaining_pro: 500 },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Max")
  })

  it("shows both API credits and rate-limit lines for hybrid user", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, balance: 10.0 },
      usageAnalytics: [{ meter_event_summaries: [{ cost: 2.5 }] }],
      rateLimits: { remaining_pro: 150, remaining_research: 15 },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(result.lines.length).toBe(3)
    expect(result.lines[0].type).toBe("progress")
    expect(result.lines[0].label).toBe("API credits")
    expect(result.lines[0].used).toBe(2.5)
    expect(result.lines[0].limit).toBe(10.0)
    expect(result.lines[1].type).toBe("text")
    expect(result.lines[1].label).toBe("Queries")
    expect(result.lines[2].label).toBe("Deep Research")
  })

  it("shows exhausted rate limits (remaining 0)", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, balance: 0 },
      usageAnalytics: [{ meter_event_summaries: [] }],
      rateLimits: { remaining_pro: 0, remaining_research: 0 },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(2)
    expect(result.lines[0].value).toBe("0 remaining")
    expect(result.lines[1].value).toBe("0 remaining")
  })

  it("omits rate-limit categories with undefined values", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, balance: 0 },
      usageAnalytics: [{ meter_event_summaries: [] }],
      rateLimits: { remaining_pro: 100 },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.length).toBe(1)
    expect(result.lines[0].label).toBe("Queries")
  })

  it("fetches rate-limit endpoint with auth headers", async () => {
    const ctx = makeCtx()
    const token = makeJwtLikeToken()
    mockCacheSession(ctx, { requestHex: makeRequestHexWithBearer(token) })
    mockRestApi(ctx, {
      customerInfo: { is_pro: true, balance: 0 },
      usageAnalytics: [{ meter_event_summaries: [] }],
      rateLimits: { remaining_pro: 100 },
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const rateLimitCall = ctx.host.http.request.mock.calls.find((call) =>
      String(call[0]?.url).includes("/rest/rate-limit/all")
    )?.[0]

    expect(rateLimitCall).toBeTruthy()
    expect(rateLimitCall.headers.Authorization).toBe("Bearer " + token)
  })
})
