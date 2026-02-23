import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeJwt(payload) {
  const jwtPayload = Buffer.from(JSON.stringify(payload), "utf8")
    .toString("base64")
    .replace(/=+$/g, "")
  return `a.${jwtPayload}.c`
}

describe("cursor plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no token", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("loads tokens from keychain when sqlite has none", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "cursor-access-token") return "keychain-access-token"
      if (service === "cursor-refresh-token") return "keychain-refresh-token"
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        enabled: true,
        planUsage: { totalSpend: 1200, limit: 2400 },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("cursor-access-token")
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("cursor-refresh-token")
  })

  it("refreshes keychain access token and persists to keychain source", async () => {
    const ctx = makeCtx()
    const expiredPayload = Buffer.from(JSON.stringify({ exp: 1 }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const expiredAccessToken = `a.${expiredPayload}.c`
    const freshPayload = Buffer.from(JSON.stringify({ exp: 9999999999 }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const refreshedAccessToken = `a.${freshPayload}.c`

    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "cursor-access-token") return expiredAccessToken
      if (service === "cursor-refresh-token") return "keychain-refresh-token"
      return null
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/oauth/token")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ access_token: refreshedAccessToken }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          enabled: true,
          planUsage: { totalSpend: 1200, limit: 2400 },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
    expect(ctx.host.keychain.writeGenericPassword).toHaveBeenCalledWith(
      "cursor-access-token",
      refreshedAccessToken
    )
    expect(ctx.host.sqlite.exec).not.toHaveBeenCalled()
  })

  it("prefers sqlite tokens when sqlite and keychain both have tokens", async () => {
    const ctx = makeCtx()
    const sqlitePayload = Buffer.from(JSON.stringify({ exp: 9999999999 }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const sqliteToken = `a.${sqlitePayload}.c`
    const keychainPayload = Buffer.from(JSON.stringify({ exp: 9999999999, sub: "keychain" }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const keychainToken = `a.${keychainPayload}.c`

    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([{ value: sqliteToken }])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) {
        return JSON.stringify([{ value: "sqlite-refresh-token" }])
      }
      return JSON.stringify([])
    })
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "cursor-access-token") return keychainToken
      if (service === "cursor-refresh-token") return "keychain-refresh-token"
      return null
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        expect(opts.headers.Authorization).toBe("Bearer " + sqliteToken)
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          enabled: true,
          planUsage: { totalSpend: 1200, limit: 2400 },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPassword).not.toHaveBeenCalled()
  })

  it("throws on sqlite errors when reading token", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    expect(ctx.host.log.warn).toHaveBeenCalled()
  })

  it("throws on disabled usage", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ enabled: false }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No active Cursor subscription.")
  })

  it("throws on missing plan usage data", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ enabled: true }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No active Cursor subscription.")
  })

  it("accepts team usage when enabled flag is missing", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770064133000",
            billingCycleEnd: "1772483333000",
            planUsage: { totalSpend: 8474, limit: 2000, bonusSpend: 6474 },
            spendLimitUsage: {
              pooledLimit: 60000,
              pooledRemaining: 19216,
            },
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ planInfo: { planName: "Team" } }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Team")
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })

  it("throws on missing plan usage limit", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        enabled: true,
        planUsage: { totalSpend: 1200 }, // missing limit
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Plan usage limit missing")
  })

  it("calculates planUsed from limit - remaining when totalSpend missing", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        enabled: true,
        planUsage: { limit: 2400, remaining: 1200 }, // no totalSpend
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const planLine = result.lines.find((l) => l.label === "Plan usage")
    expect(planLine).toBeTruthy()
    // used = limit - remaining = 2400 - 1200 = 1200
    expect(planLine.used).toBe(12) // ctx.fmt.dollars divides by 100
  })

  it("renders usage + plan info", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400, bonusSpend: 100 },
            spendLimitUsage: { individualLimit: 5000, individualRemaining: 1000 },
            billingCycleEnd: Date.now(),
          }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ planInfo: { planName: "pro plan" } }),
      }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })

  it("omits plan badge for blank plan names", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
          }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ planInfo: { planName: "   " } }),
      }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeFalsy()
  })

  it("uses pooled spend limits when individual values missing", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
            spendLimitUsage: { pooledLimit: 2000, pooledRemaining: 500 },
          }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ planInfo: { planName: "pro plan" } }),
      }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "On-demand")).toBeTruthy()
  })

  it("throws on token expired", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("throws on http errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on usage request errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed")
  })

  it("throws on parse errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: "not-json",
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("handles enterprise account with request-based usage", async () => {
    const ctx = makeCtx()

    // Build a JWT with a sub claim containing a user ID
    const jwtPayload = Buffer.from(
      JSON.stringify({ sub: "google-oauth2|user_abc123", exp: 9999999999 }),
      "utf8"
    )
      .toString("base64")
      .replace(/=+$/g, "")
    const accessToken = `a.${jwtPayload}.c`

    ctx.host.sqlite.query.mockReturnValue(
      JSON.stringify([{ value: accessToken }])
    )
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        // Enterprise returns no enabled/planUsage
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770539602363",
            billingCycleEnd: "1770539602363",
            displayThreshold: 100,
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            planInfo: { planName: "Enterprise", price: "Custom" },
          }),
        }
      }
      if (String(opts.url).includes("cursor.com/api/usage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            "gpt-4": {
              numRequests: 422,
              numRequestsTotal: 422,
              numTokens: 171664819,
              maxRequestUsage: 500,
              maxTokenUsage: null,
            },
            startOfMonth: "2026-02-01T06:12:57.000Z",
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Enterprise")
    const reqLine = result.lines.find((l) => l.label === "Included requests")
    expect(reqLine).toBeTruthy()
    expect(reqLine.used).toBe(422)
    expect(reqLine.limit).toBe(500)
    expect(reqLine.format).toEqual({ kind: "count", suffix: "requests" })
  })

  it("throws when enterprise REST usage API fails", async () => {
    const ctx = makeCtx()

    const jwtPayload = Buffer.from(
      JSON.stringify({ sub: "google-oauth2|user_abc123", exp: 9999999999 }),
      "utf8"
    )
      .toString("base64")
      .replace(/=+$/g, "")
    const accessToken = `a.${jwtPayload}.c`

    ctx.host.sqlite.query.mockReturnValue(
      JSON.stringify([{ value: accessToken }])
    )
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770539602363",
            billingCycleEnd: "1770539602363",
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            planInfo: { planName: "Enterprise" },
          }),
        }
      }
      if (String(opts.url).includes("cursor.com/api/usage")) {
        return { status: 500, bodyText: "" }
      }
      return { status: 200, bodyText: "{}" }
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Enterprise usage data unavailable")
  })

  it("still throws no subscription for non-enterprise accounts without planUsage", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ enabled: false }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ planInfo: { planName: "Pro" } }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("No active Cursor subscription.")
  })

  it("handles plan fetch failure gracefully", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 0, limit: 100 },
          }),
        }
      }
      // Plan fetch fails
      throw new Error("plan fail")
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })

  it("outputs Credits first when available", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
            spendLimitUsage: { individualLimit: 5000, individualRemaining: 1000 },
          }),
        }
      }
      if (String(opts.url).includes("GetCreditGrantsBalance")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            hasCreditGrants: true,
            totalCents: 10000,
            usedCents: 500,
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    
    // Credits should be first in the lines array
    expect(result.lines[0].label).toBe("Credits")
    expect(result.lines[1].label).toBe("Plan usage")
    // On-demand should come after
    const onDemandIndex = result.lines.findIndex((l) => l.label === "On-demand")
    expect(onDemandIndex).toBeGreaterThan(1)
  })

  it("outputs Plan usage first when Credits not available", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
          }),
        }
      }
      if (String(opts.url).includes("GetCreditGrantsBalance")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ hasCreditGrants: false }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    
    // Plan usage should be first when Credits not available
    expect(result.lines[0].label).toBe("Plan usage")
  })

  it("refreshes token when expired and persists new access token", async () => {
    const ctx = makeCtx()

    const expiredPayload = Buffer.from(JSON.stringify({ exp: 1 }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const accessToken = `a.${expiredPayload}.c`

    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([{ value: accessToken }])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) {
        return JSON.stringify([{ value: "refresh" }])
      }
      return JSON.stringify([])
    })

    const newPayload = Buffer.from(JSON.stringify({ exp: 9999999999 }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const newToken = `a.${newPayload}.c`

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: newToken }) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ enabled: true, planUsage: { totalSpend: 0, limit: 100 } }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
    expect(ctx.host.sqlite.exec).toHaveBeenCalled()
  })

  it("throws session expired when refresh requires logout and no access token exists", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) {
        return JSON.stringify([{ value: "refresh" }])
      }
      return JSON.stringify([])
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ shouldLogout: true }) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("continues with existing access token when refresh fails", async () => {
    const ctx = makeCtx()

    const payload = Buffer.from(JSON.stringify({ exp: 1 }), "utf8")
      .toString("base64")
      .replace(/=+$/g, "")
    const accessToken = `a.${payload}.c`

    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([{ value: accessToken }])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) {
        return JSON.stringify([{ value: "refresh" }])
      }
      return JSON.stringify([])
    })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/oauth/token")) {
        // Force refresh to throw string error.
        return { status: 401, bodyText: JSON.stringify({ shouldLogout: true }) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({ enabled: true, planUsage: { totalSpend: 0, limit: 100 } }),
      }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
  })

  it("handles invalid sqlite JSON for access token when refresh token is available", async () => {
    const ctx = makeCtx()
    const refreshedToken = makeJwt({ sub: "google-oauth2|user_abc123", exp: 9999999999 })

    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) return "{}"
      if (String(sql).includes("cursorAuth/refreshToken")) return JSON.stringify([{ value: "refresh" }])
      return JSON.stringify([])
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: refreshedToken }) }
      }
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return { status: 200, bodyText: JSON.stringify({ enabled: true, planUsage: { totalSpend: 0, limit: 100 } }) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })

  it("throws not logged in when only refresh token exists but refresh returns no access token", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) return JSON.stringify([])
      if (String(sql).includes("cursorAuth/refreshToken")) return JSON.stringify([{ value: "refresh" }])
      return JSON.stringify([])
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({}) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws token expired when usage remains unauthorized after refresh retry", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([{ value: makeJwt({ sub: "google-oauth2|u", exp: 9999999999 }) }])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) return JSON.stringify([{ value: "refresh" }])
      return JSON.stringify([])
    })

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        usageCalls += 1
        if (usageCalls === 1) return { status: 401, bodyText: "" }
        return { status: 403, bodyText: "" }
      }
      if (String(opts.url).includes("/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: makeJwt({ sub: "google-oauth2|u", exp: 9999999999 }) }) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("throws usage request failed after refresh when retried usage request errors", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([{ value: makeJwt({ sub: "google-oauth2|u", exp: 9999999999 }) }])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) return JSON.stringify([{ value: "refresh" }])
      return JSON.stringify([])
    })

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        usageCalls += 1
        if (usageCalls === 1) return { status: 401, bodyText: "" }
        throw new Error("boom")
      }
      if (String(opts.url).includes("/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: makeJwt({ sub: "google-oauth2|u", exp: 9999999999 }) }) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed after refresh")
  })

  it("throws enterprise unavailable when token payload has no sub", async () => {
    const ctx = makeCtx()
    const accessToken = makeJwt({ exp: 9999999999 })
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: accessToken }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return { status: 200, bodyText: JSON.stringify({ billingCycleStart: "1770539602363" }) }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return { status: 200, bodyText: JSON.stringify({ planInfo: { planName: "Enterprise" } }) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Enterprise usage data unavailable")
  })

  it("supports enterprise JWT sub values without provider prefix", async () => {
    const ctx = makeCtx()
    const accessToken = makeJwt({ sub: "user_abc123", exp: 9999999999 })
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: accessToken }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770539602363",
            billingCycleEnd: "1770539602363",
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            planInfo: { planName: "Enterprise" },
          }),
        }
      }
      if (String(opts.url).includes("cursor.com/api/usage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            "gpt-4": {
              numRequests: 3,
              maxRequestUsage: 10,
            },
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Enterprise")
    const reqLine = result.lines.find((l) => l.label === "Included requests")
    expect(reqLine).toBeTruthy()
    expect(reqLine.used).toBe(3)
    expect(reqLine.limit).toBe(10)
  })

  it("uses zero default for missing remaining and omits zero on-demand limits", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { limit: 2400 },
            spendLimitUsage: {},
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const planLine = result.lines.find((line) => line.label === "Plan usage")
    expect(planLine).toBeTruthy()
    expect(planLine.used).toBe(24)
    expect(result.lines.find((line) => line.label === "On-demand")).toBeUndefined()
  })

  it("rethrows string errors from retry wrapper", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.util.retryOnceOnAuth = vi.fn(() => {
      throw "retry failed"
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("retry failed")
  })

  it("skips malformed credit grants payload and still returns plan usage", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 1200, limit: 2400 },
          }),
        }
      }
      if (String(opts.url).includes("GetCreditGrantsBalance")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            hasCreditGrants: true,
            totalCents: "oops",
            usedCents: "10",
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Credits")).toBeUndefined()
    expect(result.lines.find((line) => line.label === "Plan usage")).toBeTruthy()
  })

  it("uses expired access token when refresh token is missing", async () => {
    const ctx = makeCtx()
    const expiredToken = makeJwt({ sub: "google-oauth2|user_abc123", exp: 1 })
    ctx.host.sqlite.query.mockImplementation((db, sql) => {
      if (String(sql).includes("cursorAuth/accessToken")) {
        return JSON.stringify([{ value: expiredToken }])
      }
      if (String(sql).includes("cursorAuth/refreshToken")) return JSON.stringify([])
      return JSON.stringify([])
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            enabled: true,
            planUsage: { totalSpend: 0, limit: 100 },
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
  })

  it("throws enterprise unavailable when sub resolves to empty user id", async () => {
    const ctx = makeCtx()
    const accessToken = makeJwt({ sub: "google-oauth2|", exp: 9999999999 })
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: accessToken }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return { status: 200, bodyText: JSON.stringify({ billingCycleStart: "1770539602363" }) }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return { status: 200, bodyText: JSON.stringify({ planInfo: { planName: "Enterprise" } }) }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Enterprise usage data unavailable")
  })

  it("uses zero included requests when enterprise usage omits numRequests", async () => {
    const ctx = makeCtx()
    const accessToken = makeJwt({ sub: "google-oauth2|user_abc123", exp: 9999999999 })
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: accessToken }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770539602363",
            billingCycleEnd: "1770539602363",
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            planInfo: { planName: "Enterprise" },
          }),
        }
      }
      if (String(opts.url).includes("cursor.com/api/usage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            "gpt-4": {
              maxRequestUsage: 10,
            },
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const reqLine = result.lines.find((line) => line.label === "Included requests")
    expect(reqLine).toBeTruthy()
    expect(reqLine.used).toBe(0)
    expect(reqLine.limit).toBe(10)
  })

  it("throws enterprise unavailable when gpt-4 request limit is not positive", async () => {
    const ctx = makeCtx()
    const accessToken = makeJwt({ sub: "google-oauth2|user_abc123", exp: 9999999999 })
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: accessToken }]))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770539602363",
            billingCycleEnd: "1770539602363",
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            planInfo: { planName: "Enterprise" },
          }),
        }
      }
      if (String(opts.url).includes("cursor.com/api/usage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            "gpt-4": {
              numRequests: 42,
              maxRequestUsage: 0,
            },
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Enterprise usage data unavailable")
  })

  it("omits enterprise plan label when formatter returns null", async () => {
    const ctx = makeCtx()
    const accessToken = makeJwt({ sub: "google-oauth2|user_abc123", exp: 9999999999 })
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: accessToken }]))
    ctx.fmt.planLabel = vi.fn(() => null)
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("GetCurrentPeriodUsage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            billingCycleStart: "1770539602363",
            billingCycleEnd: "1770539602363",
          }),
        }
      }
      if (String(opts.url).includes("GetPlanInfo")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            planInfo: { planName: "Enterprise" },
          }),
        }
      }
      if (String(opts.url).includes("cursor.com/api/usage")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            "gpt-4": {
              numRequests: 3,
              maxRequestUsage: 10,
            },
          }),
        }
      }
      return { status: 200, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((line) => line.label === "Included requests")).toBeTruthy()
  })

  it("wraps non-string retry wrapper errors as usage request failure", async () => {
    const ctx = makeCtx()
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "token" }]))
    ctx.util.retryOnceOnAuth = vi.fn(() => {
      throw new Error("wrapper blew up")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })
})
