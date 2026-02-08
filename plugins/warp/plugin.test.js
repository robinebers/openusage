import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeGraphqlResponse(userData) {
  return {
    status: 200,
    headers: {},
    bodyText: JSON.stringify({ data: { user: { user: userData } } }),
  }
}

function keychainJson(idToken) {
  return JSON.stringify({
    id_token: { id_token: idToken, refresh_token: "rt", expiration_time: "2099-01-01T00:00:00Z" },
    refresh_token: "",
    local_id: "abc",
    email: "test@example.com",
  })
}

describe("warp plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when not logged in (no keychain, no env, no file)", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("reads token from macOS Keychain automatically", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockImplementation((service, account) => {
      expect(service).toBe("dev.warp.Warp-Stable")
      expect(account).toBe("User")
      return keychainJson("keychain-token")
    })
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer keychain-token")
      return makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: false, requestLimit: 100, requestsUsedSinceLastRefresh: 10 },
      })
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Credits")).toBeTruthy()
  })

  it("falls back to WARP_API_KEY env var when keychain unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockImplementation(() => { throw new Error("not found") })
    ctx.host.env.get.mockImplementation((name) =>
      name === "WARP_API_KEY" ? "env-key" : null
    )
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer env-key")
      return makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: false, requestLimit: 100, requestsUsedSinceLastRefresh: 10 },
      })
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Credits")).toBeTruthy()
  })

  it("falls back to WARP_TOKEN env var", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockImplementation(() => { throw new Error("not found") })
    ctx.host.env.get.mockImplementation((name) =>
      name === "WARP_TOKEN" ? "token-from-env" : null
    )
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer token-from-env")
      return makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: false, requestLimit: 50, requestsUsedSinceLastRefresh: 5 },
      })
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Credits")).toBeTruthy()
  })

  it("falls back to api-key.txt file", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockImplementation(() => { throw new Error("not found") })
    ctx.host.fs.writeText(ctx.app.pluginDataDir + "/api-key.txt", "file-key\n")
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer file-key")
      return makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: false, requestLimit: 100, requestsUsedSinceLastRefresh: 0 },
      })
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Credits")).toBeTruthy()
  })

  it("keychain takes priority over env vars", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("keychain-wins"))
    ctx.host.env.get.mockImplementation((name) =>
      name === "WARP_API_KEY" ? "env-loses" : null
    )
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer keychain-wins")
      return makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: false, requestLimit: 100, requestsUsedSinceLastRefresh: 0 },
      })
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("handles keychain entry with missing id_token", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(JSON.stringify({ id_token: null }))
    ctx.host.env.get.mockImplementation((name) =>
      name === "WARP_API_KEY" ? "fallback-key" : null
    )
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: false, requestLimit: 100, requestsUsedSinceLastRefresh: 0 },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Credits")).toBeTruthy()
  })

  it("throws on 401 auth error", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("bad-token"))
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws on 403 auth error", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("bad-token"))
    ctx.host.http.request.mockReturnValue({ status: 403, headers: {}, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws on 500 server error", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue({ status: 500, headers: {}, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on invalid JSON response", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue({ status: 200, headers: {}, bodyText: "not json" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Invalid response")
  })

  it("throws on unexpected response shape", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({ data: { user: {} } }),
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Unexpected response")
  })

  it("parses standard usage with credits and resetsAt", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    const nextRefresh = "2026-02-10T00:00:00Z"
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: {
          isUnlimited: false,
          requestLimit: 200,
          requestsUsedSinceLastRefresh: 75,
          nextRefreshTime: nextRefresh,
        },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const credits = result.lines.find((l) => l.label === "Credits")
    expect(credits).toBeTruthy()
    expect(credits.used).toBe(75)
    expect(credits.limit).toBe(200)
    expect(credits.format).toEqual({ kind: "count", suffix: "requests" })
    expect(credits.resetsAt).toBe("2026-02-10T00:00:00.000Z")
  })

  it("shows unlimited badge when isUnlimited is true", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: true },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const badge = result.lines.find((l) => l.label === "Credits")
    expect(badge).toBeTruthy()
    expect(badge.type).toBe("badge")
    expect(badge.text).toBe("Unlimited")
  })

  it("shows user bonus credits", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: {
          isUnlimited: false,
          requestLimit: 100,
          requestsUsedSinceLastRefresh: 10,
        },
        bonusGrants: [
          { requestCreditsGranted: 50, requestCreditsRemaining: 30, expiration: null },
        ],
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const bonus = result.lines.find((l) => l.label === "Bonus")
    expect(bonus).toBeTruthy()
    expect(bonus.used).toBe(20)
    expect(bonus.limit).toBe(50)
  })

  it("combines user and workspace bonus grants", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: {
          isUnlimited: false,
          requestLimit: 100,
          requestsUsedSinceLastRefresh: 0,
        },
        bonusGrants: [
          { requestCreditsGranted: 50, requestCreditsRemaining: 40, expiration: null },
        ],
        workspaces: [
          {
            bonusGrantsInfo: {
              grants: [
                { requestCreditsGranted: 100, requestCreditsRemaining: 80, expiration: null },
              ],
            },
          },
        ],
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const bonus = result.lines.find((l) => l.label === "Bonus")
    expect(bonus).toBeTruthy()
    expect(bonus.used).toBe(30) // (50-40) + (100-80)
    expect(bonus.limit).toBe(150) // 50 + 100
  })

  it("omits bonus line when no grants exist", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: {
          isUnlimited: false,
          requestLimit: 100,
          requestsUsedSinceLastRefresh: 50,
        },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Bonus")).toBeFalsy()
  })

  it("shows no usage data badge when limit is zero", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockReturnValue(
      makeGraphqlResponse({
        requestLimitInfo: {
          isUnlimited: false,
          requestLimit: 0,
          requestsUsedSinceLastRefresh: 0,
        },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Status")
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("throws on network error", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("token"))
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("connection refused")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed")
  })

  it("sends correct GraphQL request", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(keychainJson("my-token"))
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.method).toBe("POST")
      expect(opts.url).toContain("app.warp.dev/graphql/v2")
      expect(opts.url).toContain("op=GetRequestLimitInfo")
      expect(opts.headers["Content-Type"]).toBe("application/json")
      expect(opts.headers["x-warp-client-id"]).toBe("warp-app")
      const body = JSON.parse(opts.bodyText)
      expect(body.operationName).toBe("GetRequestLimitInfo")
      expect(body.query).toContain("requestLimitInfo")
      return makeGraphqlResponse({
        requestLimitInfo: { isUnlimited: true },
      })
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })
})
