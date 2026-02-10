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
  const usageAnalytics = options.usageAnalytics ?? [
    { meter_event_summaries: [{ usage: 1, cost: 0.04 }] },
  ]

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
        bodyText: JSON.stringify({ customerInfo: { balance, is_pro: isPro } }),
      }
    }

    if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify(usageAnalytics),
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

  it("returns only a Usage progress bar (primary cache path)", async () => {
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
    expect(line.label).toBe("Usage")
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
    expect(result.lines[0].label).toBe("Usage")
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

  it("throws when usage analytics is unavailable (avoid false $0 used)", async () => {
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
          bodyText: JSON.stringify({ customerInfo: { balance: 4.99, is_pro: true } }),
        }
      }
      if (req.url === `https://www.perplexity.ai/rest/pplx-api/v2/groups/${GROUP_ID}/usage-analytics`) {
        return { status: 403, headers: {}, bodyText: "<html>Just a moment...</html>" }
      }
      return { status: 404, headers: {}, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage unavailable")
  })
})
