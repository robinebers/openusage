import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const CRED_PATH = "~/.kimi/credentials/kimi-code.json"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

describe("kimi plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when credentials are missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("refreshes token and renders session + weekly usage", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      CRED_PATH,
      JSON.stringify({
        access_token: "old-token",
        refresh_token: "refresh-token",
        expires_at: 1,
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("/api/oauth/token")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: "new-token",
            refresh_token: "new-refresh",
            expires_in: 3600,
            scope: "kimi-code",
            token_type: "Bearer",
          }),
        }
      }

      return {
        status: 200,
        bodyText: JSON.stringify({
          usage: {
            limit: "100",
            remaining: "74",
            resetTime: "2099-02-11T17:32:50.757941Z",
          },
          limits: [
            {
              window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" },
              detail: {
                limit: "100",
                remaining: "85",
                resetTime: "2099-02-07T12:32:50.757941Z",
              },
            },
          ],
          user: {
            membership: {
              level: "LEVEL_INTERMEDIATE",
            },
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Intermediate")
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()

    const persisted = JSON.parse(ctx.host.fs.readText(CRED_PATH))
    expect(persisted.access_token).toBe("new-token")
    expect(persisted.refresh_token).toBe("new-refresh")
  })

  it("retries usage once on 401 by refreshing token", async () => {
    const ctx = makeCtx()
    const nowSec = Math.floor(Date.now() / 1000)
    ctx.host.fs.writeText(
      CRED_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expires_at: nowSec + 3600,
      })
    )

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("/usages")) {
        usageCalls += 1
        if (usageCalls === 1) {
          return { status: 401, bodyText: "" }
        }
        return {
          status: 200,
          bodyText: JSON.stringify({
            usage: { limit: "100", remaining: "100", resetTime: "2099-02-11T00:00:00Z" },
            limits: [
              {
                window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" },
                detail: { limit: "100", remaining: "100", resetTime: "2099-02-07T00:00:00Z" },
              },
            ],
          }),
        }
      }

      return {
        status: 200,
        bodyText: JSON.stringify({
          access_token: "token-2",
          refresh_token: "refresh-2",
          expires_in: 3600,
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(usageCalls).toBe(2)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("throws session expired when refresh is unauthorized", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      CRED_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expires_at: 1,
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("/api/oauth/token")) {
        return { status: 401, bodyText: JSON.stringify({ error: "unauthorized" }) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws on invalid usage payload", async () => {
    const ctx = makeCtx()
    const nowSec = Math.floor(Date.now() / 1000)
    ctx.host.fs.writeText(
      CRED_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expires_at: nowSec + 3600,
      })
    )

    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: "not-json",
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })
})
