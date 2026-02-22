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

  it("omits token lines when ccusage reports no_runner", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    ctx.host.ccusage.query.mockReturnValue({ status: "no_runner" })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Today")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Yesterday")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Last 30 Days")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
  })

  it("adds token lines from codex ccusage format and passes codex provider", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-20T16:00:00.000Z"))

    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    const now = new Date()
    const month = now.toLocaleString("en-US", { month: "short" })
    const day = String(now.getDate()).padStart(2, "0")
    const year = now.getFullYear()
    const todayKey = month + " " + day + ", " + year
    ctx.host.ccusage.query.mockReturnValue({
      status: "ok",
      data: {
        daily: [
        { date: todayKey, totalTokens: 150, costUSD: 0.75 },
        { date: "Feb 01, 2026", totalTokens: 300, costUSD: 1.0 },
        ],
      },
    })

    try {
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      const today = result.lines.find((l) => l.label === "Today")
      expect(today).toBeTruthy()
      expect(today.value).toContain("150 tokens")
      expect(today.value).toContain("$0.75")

      const last30 = result.lines.find((l) => l.label === "Last 30 Days")
      expect(last30).toBeTruthy()
      expect(last30.value).toContain("450 tokens")
      expect(last30.value).toContain("$1.75")

      expect(ctx.host.ccusage.query).toHaveBeenCalled()
      const firstCall = ctx.host.ccusage.query.mock.calls[0][0]
      expect(firstCall.provider).toBe("codex")
      const since = new Date()
      since.setDate(since.getDate() - 30)
      const sinceYear = String(since.getFullYear())
      const sinceMonth = String(since.getMonth() + 1).padStart(2, "0")
      const sinceDay = String(since.getDate()).padStart(2, "0")
      expect(firstCall.since).toBe(sinceYear + sinceMonth + sinceDay)
    } finally {
      vi.useRealTimers()
    }
  })

  it("passes CODEX_HOME to ccusage via homePath", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "CODEX_HOME" ? "/tmp/codex-home" : null))
    ctx.host.fs.writeText("/tmp/codex-home/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    ctx.host.ccusage.query.mockReturnValue({ status: "ok", data: { daily: [] } })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(ctx.host.ccusage.query).toHaveBeenCalled()
    const firstCall = ctx.host.ccusage.query.mock.calls[0][0]
    expect(firstCall.homePath).toBe("/tmp/codex-home")
  })

  it("queries ccusage on each probe", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    ctx.host.ccusage.query.mockReturnValue({
      status: "ok",
      data: { daily: [{ date: "2026-02-01", totalTokens: 100, totalCost: 0.5 }] },
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
    plugin.probe(ctx)

    expect(ctx.host.ccusage.query).toHaveBeenCalledTimes(2)
  })

  it("shows empty Today state when ccusage returns ok with empty daily array", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    ctx.host.ccusage.query.mockReturnValue({ status: "ok", data: { daily: [] } })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const todayLine = result.lines.find((l) => l.label === "Today")
    expect(todayLine).toBeTruthy()
    expect(todayLine.value).toContain("$0.00")
    expect(todayLine.value).toContain("0 tokens")
    const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
    expect(yesterdayLine).toBeTruthy()
    expect(yesterdayLine.value).toContain("$0.00")
    expect(yesterdayLine.value).toContain("0 tokens")
    expect(result.lines.find((l) => l.label === "Last 30 Days")).toBeUndefined()
  })

  it("shows empty Yesterday state when yesterday's totals are zero (regression)", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    const yesterday = new Date()
    yesterday.setDate(yesterday.getDate() - 1)
    const month = yesterday.toLocaleString("en-US", { month: "short" })
    const day = String(yesterday.getDate()).padStart(2, "0")
    const year = yesterday.getFullYear()
    const yesterdayKey = month + " " + day + ", " + year
    ctx.host.ccusage.query.mockReturnValue({
      status: "ok",
      data: {
        daily: [
        { date: yesterdayKey, totalTokens: 0, costUSD: 0 },
        ],
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
    expect(yesterdayLine).toBeTruthy()
    expect(yesterdayLine.value).toContain("$0.00")
    expect(yesterdayLine.value).toContain("0 tokens")
  })

  it("shows empty Today when history exists but today is missing (regression)", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    ctx.host.ccusage.query.mockReturnValue({
      status: "ok",
      data: {
        daily: [
        { date: "Feb 01, 2026", totalTokens: 300, costUSD: 1.0 },
        ],
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const todayLine = result.lines.find((l) => l.label === "Today")
    expect(todayLine).toBeTruthy()
    expect(todayLine.value).toContain("$0.00")
    expect(todayLine.value).toContain("0 tokens")
    const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
    expect(yesterdayLine).toBeTruthy()
    expect(yesterdayLine.value).toContain("$0.00")
    expect(yesterdayLine.value).toContain("0 tokens")

    const last30 = result.lines.find((l) => l.label === "Last 30 Days")
    expect(last30).toBeTruthy()
    expect(last30.value).toContain("300 tokens")
    expect(last30.value).toContain("$1.00")
  })

  it("adds Yesterday line from codex ccusage format", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    const yesterday = new Date()
    yesterday.setDate(yesterday.getDate() - 1)
    const month = yesterday.toLocaleString("en-US", { month: "short" })
    const day = String(yesterday.getDate()).padStart(2, "0")
    const year = yesterday.getFullYear()
    const yesterdayKey = month + " " + day + ", " + year
    ctx.host.ccusage.query.mockReturnValue({
      status: "ok",
      data: {
        daily: [
        { date: yesterdayKey, totalTokens: 220, costUSD: 1.1 },
        ],
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
    expect(yesterdayLine).toBeTruthy()
    expect(yesterdayLine.value).toContain("220 tokens")
    expect(yesterdayLine.value).toContain("$1.10")
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

  it("shows status badge when no usage data and ccusage failed", async () => {
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
    ctx.host.ccusage.query.mockReturnValue({ status: "runner_failed" })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Today")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Yesterday")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Last 30 Days")).toBeUndefined()
    const statusLine = result.lines.find((l) => l.label === "Status")
    expect(statusLine).toBeTruthy()
    expect(statusLine.text).toBe("No usage data")
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

  it("surfaces additional_rate_limits as Spark lines", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    const now = 1_700_000_000_000
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    const nowSec = Math.floor(now / 1000)

    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        rate_limit: {
          primary_window: { used_percent: 5, reset_after_seconds: 60 },
          secondary_window: { used_percent: 10, reset_after_seconds: 120 },
        },
        additional_rate_limits: [
          {
            limit_name: "GPT-5.3-Codex-Spark",
            metered_feature: "codex_bengalfox",
            rate_limit: {
              primary_window: {
                used_percent: 25,
                limit_window_seconds: 18000,
                reset_after_seconds: 3600,
                reset_at: nowSec + 3600,
              },
              secondary_window: {
                used_percent: 40,
                limit_window_seconds: 604800,
                reset_after_seconds: 86400,
                reset_at: nowSec + 86400,
              },
            },
          },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const spark = result.lines.find((l) => l.label === "Spark")
    expect(spark).toBeTruthy()
    expect(spark.used).toBe(25)
    expect(spark.limit).toBe(100)
    expect(spark.periodDurationMs).toBe(18000000)
    expect(spark.resetsAt).toBe(new Date((nowSec + 3600) * 1000).toISOString())

    const sparkWeekly = result.lines.find((l) => l.label === "Spark Weekly")
    expect(sparkWeekly).toBeTruthy()
    expect(sparkWeekly.used).toBe(40)
    expect(sparkWeekly.limit).toBe(100)
    expect(sparkWeekly.periodDurationMs).toBe(604800000)
    expect(sparkWeekly.resetsAt).toBe(new Date((nowSec + 86400) * 1000).toISOString())

    nowSpy.mockRestore()
  })

  it("handles additional_rate_limits with missing fields and fallback labels", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        additional_rate_limits: [
          // Entry with no limit_name, no limit_window_seconds, no secondary
          {
            limit_name: "",
            rate_limit: {
              primary_window: { used_percent: 10, reset_after_seconds: 60 },
              secondary_window: null,
            },
          },
          // Malformed entry (no rate_limit)
          { limit_name: "Bad" },
          // Null entry
          null,
        ],
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const modelLine = result.lines.find((l) => l.label === "Model")
    expect(modelLine).toBeTruthy()
    expect(modelLine.used).toBe(10)
    expect(modelLine.periodDurationMs).toBe(5 * 60 * 60 * 1000) // fallback PERIOD_SESSION_MS
    // No weekly line for this entry since secondary_window is null
    expect(result.lines.find((l) => l.label === "Model Weekly")).toBeUndefined()
    // Malformed and null entries should be skipped
    expect(result.lines.find((l) => l.label === "Bad")).toBeUndefined()
  })

  it("handles missing or empty additional_rate_limits gracefully", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))

    // Missing field
    ctx.host.http.request.mockReturnValueOnce({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        rate_limit: {
          primary_window: { used_percent: 5, reset_after_seconds: 60 },
        },
      }),
    })
    const plugin = await loadPlugin()
    const result1 = plugin.probe(ctx)
    expect(result1.lines.find((l) => l.label === "Spark")).toBeUndefined()

    // Empty array
    ctx.host.http.request.mockReturnValueOnce({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        rate_limit: {
          primary_window: { used_percent: 5, reset_after_seconds: 60 },
        },
        additional_rate_limits: [],
      }),
    })
    const result2 = plugin.probe(ctx)
    expect(result2.lines.find((l) => l.label === "Spark")).toBeUndefined()
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

  it("loads keychain auth when env object is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.env = null
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

  it("ignores blank CODEX_HOME and uses default auth file paths", async () => {
    const ctx = makeCtx()
    ctx.host.env.get.mockImplementation((name) => (name === "CODEX_HOME" ? "   " : null))
    ctx.host.fs.writeText("~/.config/codex/auth.json", JSON.stringify({
      tokens: { access_token: "config-token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.headers.Authorization).toBe("Bearer config-token")
      return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
  })

  it("supports uppercase 0X-prefixed keychain hex payload", async () => {
    const ctx = makeCtx()
    const raw = JSON.stringify({
      tokens: { access_token: "hex-token" },
      last_refresh: new Date().toISOString(),
    })
    const hex = "0X" + Buffer.from(raw, "utf8").toString("hex").toUpperCase()
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    const originalTextDecoder = globalThis.TextDecoder
    // Force fallback decode path used in hosts without TextDecoder.
    globalThis.TextDecoder = undefined
    try {
      ctx.host.http.request.mockImplementation((opts) => {
        expect(opts.headers.Authorization).toBe("Bearer hex-token")
        return { status: 200, headers: {}, bodyText: JSON.stringify({}) }
      })
      const plugin = await loadPlugin()
      plugin.probe(ctx)
    } finally {
      globalThis.TextDecoder = originalTextDecoder
    }
  })

  it("throws token messages for refresh_token_expired and invalidated", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "old", refresh_token: "refresh" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))
    ctx.host.http.request.mockReturnValueOnce({
      status: 400,
      headers: {},
      bodyText: JSON.stringify({ error: { code: "refresh_token_expired" } }),
    })
    let plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")

    ctx.host.http.request.mockReset()
    ctx.host.http.request.mockReturnValueOnce({
      status: 400,
      headers: {},
      bodyText: JSON.stringify({ error: { code: "refresh_token_invalidated" } }),
    })
    delete globalThis.__openusage_plugin
    vi.resetModules()
    plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token revoked")
  })

  it("falls back to existing token when refresh cannot produce new access token", async () => {
    const baseAuth = {
      tokens: { access_token: "existing", refresh_token: "refresh" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }

    const runCase = async (refreshResp) => {
      const ctx = makeCtx()
      ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify(baseAuth))
      ctx.host.http.request.mockImplementation((opts) => {
        if (String(opts.url).includes("oauth/token")) return refreshResp
        expect(opts.headers.Authorization).toBe("Bearer existing")
        return {
          status: 200,
          headers: { "x-codex-primary-used-percent": "5" },
          bodyText: JSON.stringify({}),
        }
      })

      delete globalThis.__openusage_plugin
      vi.resetModules()
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    }

    await runCase({ status: 500, headers: {}, bodyText: "" })
    await runCase({ status: 200, headers: {}, bodyText: "not-json" })
    await runCase({ status: 200, headers: {}, bodyText: JSON.stringify({}) })
  })

  it("throws when refresh body is malformed and auth endpoint is unauthorized", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "old", refresh_token: "refresh" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 401,
      headers: {},
      bodyText: "{bad",
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("uses no_runner when ccusage host API is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.ccusage = null
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Today")).toBeUndefined()
  })

  it("handles malformed ccusage result payload as runner_failed", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: { "x-codex-primary-used-percent": "10" },
      bodyText: JSON.stringify({}),
    })
    ctx.host.ccusage.query.mockReturnValue({ status: "ok", data: {} })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Today")).toBeUndefined()
  })

  it("formats large token totals using compact units", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-12-15T12:00:00.000Z"))
    try {
      const ctx = makeCtx()
      ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
        tokens: { access_token: "token" },
        last_refresh: new Date().toISOString(),
      }))
      ctx.host.http.request.mockReturnValue({
        status: 200,
        headers: { "x-codex-primary-used-percent": "10" },
        bodyText: JSON.stringify({}),
      })

      const now = new Date()
      const month = now.toLocaleString("en-US", { month: "short" })
      const day = String(now.getDate()).padStart(2, "0")
      const year = now.getFullYear()
      const todayKey = month + " " + day + ", " + year
      ctx.host.ccusage.query.mockReturnValue({
        status: "ok",
        data: {
          daily: [
            { date: todayKey, totalTokens: 1_250_000, totalCost: 12.5 },
            { date: "20261214", totalTokens: 25_000_000, costUSD: 50.0 },
            { date: "bad-date", totalTokens: "n/a", costUSD: "n/a" },
          ],
        },
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const today = result.lines.find((line) => line.label === "Today")
      const last30 = result.lines.find((line) => line.label === "Last 30 Days")
      expect(today && today.value).toContain("1.3M tokens")
      expect(last30 && last30.value).toContain("26M tokens")
    } finally {
      vi.useRealTimers()
    }
  })

  it("handles non-string retry wrapper exceptions", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "token" },
      last_refresh: new Date().toISOString(),
    }))
    ctx.util.retryOnceOnAuth = () => {
      throw new Error("boom")
    }

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("treats empty auth file payload as not logged in", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", "")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("handles missing keychain read API", async () => {
    const ctx = makeCtx()
    ctx.host.keychain = {}
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("ignores keychain payloads that are present but missing token-like auth", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(JSON.stringify({ user: "me" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("stores refresh and id tokens when refresh response includes them", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", JSON.stringify({
      tokens: { access_token: "old", refresh_token: "refresh" },
      last_refresh: "2000-01-01T00:00:00.000Z",
    }))

    const idToken = "header.payload.signature"
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url.includes("oauth/token")) {
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({
            access_token: "new-token",
            refresh_token: "new-refresh",
            id_token: idToken,
          }),
        }
      }
      return {
        status: 200,
        headers: { "x-codex-primary-used-percent": "1" },
        bodyText: JSON.stringify({}),
      }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    const saved = JSON.parse(ctx.host.fs.readText("~/.codex/auth.json"))
    expect(saved.tokens.refresh_token).toBe("new-refresh")
    expect(saved.tokens.id_token).toBe(idToken)
  })
})
