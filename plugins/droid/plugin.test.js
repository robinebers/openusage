import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const SESSION_FILE = "~/Library/Application Support/CodexBar/factory-session.json"
const FACTORY_AUTH_FILE = "~/.factory/auth.encrypted"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function authResponse(overrides) {
  return {
    organization: {
      name: "Factory Org",
      subscription: {
        factoryTier: "team",
        orbSubscription: { plan: { name: "Max" } },
      },
    },
    ...(overrides || {}),
  }
}

function usageResponse(overrides) {
  return {
    usage: {
      startDate: 1735689600000,
      endDate: 1738368000000,
      standard: {
        userTokens: 120000,
        totalAllowance: 1000000,
        usedRatio: 0.12,
      },
      premium: {
        userTokens: 34000,
        totalAllowance: 100000,
        usedRatio: 0.34,
      },
    },
    ...(overrides || {}),
  }
}

describe("droid plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no session/cookies are available", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("reads CodexBar session cookies and returns usage lines", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      SESSION_FILE,
      JSON.stringify({
        cookies: [
          { Name: "wos-session", Value: "session-cookie" },
          { Name: "access-token", Value: "jwt-token" },
        ],
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/app/auth/me")) {
        expect(opts.headers.Cookie).toContain("wos-session=session-cookie")
        return { status: 200, bodyText: JSON.stringify(authResponse()) }
      }

      if (String(opts.url).includes("/api/organization/subscription/usage")) {
        const body = JSON.parse(opts.bodyText)
        expect(body.useCache).toBe(true)
        return { status: 200, bodyText: JSON.stringify(usageResponse()) }
      }

      throw new Error("unexpected url " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toContain("Droid Team")

    const standard = result.lines.find((line) => line.label === "Standard")
    const premium = result.lines.find((line) => line.label === "Premium")
    const organization = result.lines.find((line) => line.label === "Organization")

    expect(standard).toBeTruthy()
    expect(standard.used).toBe(12)
    expect(standard.limit).toBe(100)
    expect(standard.resetsAt).toBeTruthy()
    expect(standard.periodDurationMs).toBe(2678400000)

    expect(premium).toBeTruthy()
    expect(premium.used).toBe(34)

    expect(organization).toBeTruthy()
    expect(organization.value).toBe("Factory Org")
  })

  it("refreshes via WorkOS when bearer token is expired", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      SESSION_FILE,
      JSON.stringify({
        bearerToken: "old-bearer",
        refreshToken: "refresh-token",
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("api.workos.com")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: "new-bearer",
            refresh_token: "new-refresh",
          }),
        }
      }

      if (String(opts.url).includes("/api/app/auth/me")) {
        const auth = opts.headers.Authorization
        if (auth === "Bearer old-bearer") {
          return { status: 401, bodyText: "{}" }
        }
        expect(auth).toBe("Bearer new-bearer")
        return { status: 200, bodyText: JSON.stringify(authResponse()) }
      }

      if (String(opts.url).includes("/api/organization/subscription/usage")) {
        return { status: 200, bodyText: JSON.stringify(usageResponse()) }
      }

      throw new Error("unexpected url " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()

    const saved = ctx.util.tryParseJson(ctx.host.fs.readText(SESSION_FILE))
    expect(saved.bearerToken).toBe("new-bearer")
    expect(saved.refreshToken).toBe("new-refresh")
  })

  it("supports manual cookie header in pluginDataDir", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      ctx.app.pluginDataDir + "/cookie-header.txt",
      "Cookie: wos-session=manual-session; access-token=manual-token"
    )

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/app/auth/me")) {
        expect(opts.headers.Cookie).toContain("wos-session=manual-session")
        return { status: 200, bodyText: JSON.stringify(authResponse()) }
      }
      if (String(opts.url).includes("/api/organization/subscription/usage")) {
        return { status: 200, bodyText: JSON.stringify(usageResponse()) }
      }
      throw new Error("unexpected url " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
  })

  it("falls back to used/allowance when usedRatio is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      SESSION_FILE,
      JSON.stringify({
        bearerToken: "token",
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/app/auth/me")) {
        return { status: 200, bodyText: JSON.stringify(authResponse()) }
      }
      if (String(opts.url).includes("/api/organization/subscription/usage")) {
        return {
          status: 200,
          bodyText: JSON.stringify(
            usageResponse({
              usage: {
                startDate: 1735689600000,
                endDate: 1738368000000,
                standard: {
                  userTokens: 250,
                  totalAllowance: 1000,
                },
              },
            })
          ),
        }
      }
      throw new Error("unexpected url " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const standard = result.lines.find((line) => line.label === "Standard")
    expect(standard).toBeTruthy()
    expect(standard.used).toBe(25)
  })

  it("loads bearer/refresh tokens from ~/.factory/auth.encrypted", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      FACTORY_AUTH_FILE,
      JSON.stringify({
        access_token: "factory-access-token",
        refresh_token: "factory-refresh-token",
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/app/auth/me")) {
        expect(opts.headers.Authorization).toBe("Bearer factory-access-token")
        return { status: 200, bodyText: JSON.stringify(authResponse()) }
      }
      if (String(opts.url).includes("/api/organization/subscription/usage")) {
        return { status: 200, bodyText: JSON.stringify(usageResponse()) }
      }
      throw new Error("unexpected url " + opts.url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Premium")).toBeTruthy()
  })
})
