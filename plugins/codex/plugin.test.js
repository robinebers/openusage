import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

describe("codex plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when auth missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("loads auth from keychain when auth file is missing", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(JSON.stringify({
      tokens: { access_token: "keychain-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer keychain-token")
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("uses CODEX_HOME auth path when env var is set", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "CODEX_HOME" ? "/tmp/codex-home" : null))
    ctx.host.fs.writeText("/tmp/codex-home/auth.json", JSON.stringify({
      tokens: { access_token: "env-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.fs.writeText("~/.config/codex/auth.json", JSON.stringify({
      tokens: { access_token: "config-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer env-token")
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("uses ~/.config/codex/auth.json before ~/.codex/auth.json when env is not set", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.config/codex/auth.json", JSON.stringify({
      tokens: { access_token: "config-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "legacy-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer config-token")
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("does not fall back when CODEX_HOME is set but missing auth file", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "CODEX_HOME" ? "/tmp/missing-codex-home" : null))
    ctx.host.fs.writeText("~/.config/codex/auth.json", JSON.stringify({
      tokens: { access_token: "config-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "legacy-token" },
      last_refresh: new Date().toISOString(),
    }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when auth json is invalid", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", "{bad")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("falls back to keychain when auth file is invalid", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", "{bad")
    ctx.host.keychain.readGenericPassword.mockReturnValue(JSON.stringify({
      tokens: { access_token: "keychain-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer keychain-token")
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("supports hex-encoded keychain auth payload", async () => {
    const ctx = makeCtx()
    const raw = JSON.stringify({
      tokens: { access_token: "hex-token" },
      last_refresh: new Date().toISOString(),
    })
    const hex = Buffer.from(raw, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer hex-token")
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("throws when auth lacks tokens and api key", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({ tokens: {} }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("refreshes token and formats usage", async () => {
    const ctx = makeCtx()
    const authPath = "~/.codex/auth.json"
    ctx.host.fs.writeText(authPath, JSON.stringify({
      tokens: { access_token: "old", refresh_token: "refresh", account_id: "acc" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new" }) }
      }
      return {
        status: 200,
        headers: {
          "x-codex-primary-used-percent": "25",
          "x-codex-secondary-used-percent": "50",
          "x-codex-credits-balance": "100",
        },
        bodyText: JSON.stringify({
          plan_type: "pro",
          rate_limit: {
            primary_window: { reset_after_seconds: 60, used_percent: 10 },
            secondary_window: { reset_after_seconds: 120, used_percent: 20 },
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()
    const credits = result.lines.find((line) => line.label === "Credits")
    expect(credits).toBeTruthy()
    expect(credits.used).toBe(900)
  })

  it("refreshes keychain auth and writes back to keychain", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(JSON.stringify({
      tokens: { access_token: "old", refresh_token: "refresh", account_id: "acc" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new" }) }
      }
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.keychain.writeGenericPassword).toHaveBeenCalled()
    const [service, payload] = ctx.host.keychain.writeGenericPassword.mock.calls[0]
    expect(service).toBe("Codex Auth")
    expect(String(payload)).toContain("\"access_token\":\"new\"")
  })

  it("throws token expired when refresh fails", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "old" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "{}" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("throws token conflict when refresh token is reused", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "old", refresh_token: "refresh" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 400,
      headers: {},
      bodyText: JSON.stringify({ error: { code: "refresh_token_reused" } }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token conflict")
  })

  it("throws for api key auth", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      OPENAI_API_KEY: "key",
    }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage not available for API key")
  })

  it("falls back to rate_limit data and review window", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        rate_limit: {
          primary_window: { used_percent: 10, reset_after_seconds: 60 },
          secondary_window: { used_percent: 20, reset_after_seconds: 120 },
        },
        code_review_rate_limit: {
          primary_window: { used_percent: 15, reset_after_seconds: 90 },
        },
        credits: { balance: 500 },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Reviews")).toBeTruthy()
    const credits = result.lines.find((line) => line.label === "Credits")
    expect(credits).toBeTruthy()
    expect(credits.used).toBe(500)
  })

  it("omits resetsAt when window lacks reset info", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({
        rate_limit: {
          primary_window: { used_percent: 10 },
        },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const sessionLine = result.lines.find((line) => line.label === "Session")
    expect(sessionLine).toBeTruthy()
    expect(sessionLine.resetsAt).toBeUndefined()
  })

  it("uses reset_at when present for resetsAt", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    const now = 1_700_000_000_000
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    const nowSec = Math.floor(now / 1000)
    const resetsAtExpected = new Date((nowSec + 60) * 1000).toISOString()

    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({
        rate_limit: {
          primary_window: { used_percent: 10, reset_at: nowSec + 60 },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((line) => line.label === "Session")
    expect(session).toBeTruthy()
    expect(session.resetsAt).toBe(resetsAtExpected)
    nowSpy.mockRestore()
  })

  it("throws on http and parse errors", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValueOnce({ status: 500, headers: {}, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")

    ctx.host.http.request.mockReturnValueOnce({ status: 200, headers: {}, bodyText: "bad" })
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("returns status when no usage data", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({}),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Status")
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("throws on usage request failures", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed")
  })

  it("throws on usage request failure after refresh", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token", refresh_token: "refresh" },
      last_refresh: new Date().toISOString(),
    }))
    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new" }) }
      }
      usageCalls += 1
      if (usageCalls === 1) {
        return { status: 401, headers: {}, bodyText: "" }
      }
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed after refresh")
  })

  it("throws token expired when refresh retry is unauthorized", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token", refresh_token: "refresh" },
      last_refresh: new Date().toISOString(),
    }))
    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new" }) }
      }
      usageCalls += 1
      if (usageCalls === 1) {
        return { status: 401, headers: {}, bodyText: "" }
      }
      return { status: 403, headers: {}, bodyText: "" }
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })
})
