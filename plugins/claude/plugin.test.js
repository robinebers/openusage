import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

let plugin = null

beforeAll(async () => {
  await import("./plugin.js")
  plugin = globalThis.__openusage_plugin
})

beforeEach(() => {
  // Reset module-scope rate-limit state so tests don't bleed into each other
  plugin?._resetState()
})

const loadPlugin = async () => plugin

const SAMPLE_PROMOCLOCK_RESPONSE = {
  status: "off_peak",
  isPeak: false,
  isOffPeak: true,
  isWeekend: false,
  sessionLimitSpeed: "normal",
  emoji: "🟢",
  label: "Off-Peak — Normal Speed",
  peakHours: "Weekdays 1pm–7pm UTC / 1:00 PM–7:00 PM GMT",
  nextChange: "2026-04-09T13:00:00.000Z",
  minutesUntilChange: 720,
  timestamp: "2026-04-09T01:00:00.000Z",
  utcHour: 1,
  utcDay: 4,
  note: "No known end date for peak hours adjustment. Weekly limits unchanged.",
}

function mockClaudeUsageAndPromoClock(
  ctx,
  {
    usageBody = {
      five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      seven_day: { utilization: 20, resets_at: "2099-01-01T00:00:00.000Z" },
    },
    usageStatus = 200,
    promoClockBody = SAMPLE_PROMOCLOCK_RESPONSE,
    promoClockStatus = 200,
    promoClockBodyText,
  } = {}
) {
  ctx.host.http.request.mockImplementation((opts) => {
    const url = String(opts && opts.url ? opts.url : "")
    if (url === "https://promoclock.co/api/status") {
      return {
        status: promoClockStatus,
        headers: {},
        bodyText:
          promoClockBodyText !== undefined
            ? promoClockBodyText
            : JSON.stringify(promoClockBody),
      }
    }

    return {
      status: usageStatus,
      headers: {},
      bodyText:
        typeof usageBody === "string"
          ? usageBody
          : JSON.stringify(usageBody),
    }
  })
}

describe("claude plugin", () => {
  it("throws when no credentials", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when credentials are unreadable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "{bad json"
    ctx.host.keychain.readGenericPassword.mockReturnValue("{bad}")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("treats credentials file read failures as missing credentials", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => {
      throw new Error("disk read failed")
    }
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    expect(ctx.host.log.warn).toHaveBeenCalled()
  })

  it("warns when credentials file exists but lacks a usable access token", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { refreshToken: "only-refresh" } })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    expect(ctx.host.log.warn).toHaveBeenCalled()
  })

  it("treats keychain read errors as missing credentials", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockImplementation(() => {
      throw new Error("keychain unavailable")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    expect(ctx.host.log.info).toHaveBeenCalled()
  })

  it("prefers current-user keychain credentials when available", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPasswordForCurrentUser).toHaveBeenCalledWith(
      "Claude Code-credentials"
    )
    expect(ctx.host.keychain.readGenericPassword).not.toHaveBeenCalled()
  })

  it("falls back to legacy keychain lookup when current-user lookup misses", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockImplementation(() => {
      throw new Error("keychain item not found")
    })
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("Claude Code-credentials")
  })

  it("falls back to keychain when credentials file is corrupt", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "{bad json"
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("reads credentials from CLAUDE_CONFIG_DIR and passes it to ccusage", async () => {
    const ctx = makeCtx()
    const configDir = "/tmp/custom-claude-home"
    const configCredFile = configDir + "/.credentials.json"
    const credsJson = JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.env.get.mockImplementation((name) => (name === "CLAUDE_CONFIG_DIR" ? configDir : null))
    ctx.host.fs.exists = vi.fn((path) => path === configCredFile)
    ctx.host.fs.readText = vi.fn((path) => {
      if (path !== configCredFile) {
        throw new Error("unexpected readText path: " + path)
      }
      return credsJson
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    ctx.host.ccusage.query = vi.fn(() => ({ status: "ok", data: { daily: [] } }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(ctx.host.fs.readText).toHaveBeenCalledWith(configCredFile)
    expect(ctx.host.ccusage.query).toHaveBeenCalledWith(
      expect.objectContaining({ homePath: configDir })
    )
  })

  it("looks up Claude Code-staging-oauth-credentials in keychain", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.env.get.mockImplementation((name) => {
      if (name === "USER_TYPE") return "ant"
      if (name === "USE_STAGING_OAUTH") return "1"
      return null
    })
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "Claude Code-staging-oauth-credentials") {
        return JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
      }
      if (service === "Claude Code-credentials") {
        return JSON.stringify({ claudeAiOauth: { refreshToken: "fallback-only" } })
      }
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith(
      "Claude Code-staging-oauth-credentials"
    )
  })

  it("uses env-injected OAuth tokens without hitting /api/oauth/usage", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.fs.readText = () => {
      throw new Error("unexpected file read")
    }
    ctx.host.env.get.mockImplementation((name) =>
      name === "CLAUDE_CODE_OAUTH_TOKEN" ? "env-oauth-token" : null
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    ctx.host.ccusage.query = vi.fn(() => ({
      status: "ok",
      data: {
        daily: [
          {
            date: "2024-01-01",
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 150,
            totalCost: 0.25,
          },
        ],
      },
    }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(
      ctx.host.http.request.mock.calls.some((call) => String(call[0]?.url).includes("/api/oauth/usage"))
    ).toBe(false)
    expect(result.lines.find((line) => line.label === "Last 30 Days")?.value).toContain("150 tokens")
  })

  it("renders usage lines from response", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        seven_day: { utilization: 20, resets_at: "2099-01-01T00:00:00.000Z" },
        extra_usage: { is_enabled: true, used_credits: 500, monthly_limit: 1000 },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Pro")
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()
  })

  describe("PromoClock integration", () => {
    it("maps the real off-peak endpoint payload to the compact badge", async () => {
      const ctx = makeCtx()
      ctx.host.fs.readText = () =>
        JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
      ctx.host.fs.exists = () => true
      mockClaudeUsageAndPromoClock(ctx)

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
      expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()
      expect(result.lines.find((line) => line.label === "Peak Hours")).toEqual({
        type: "badge",
        label: "Peak Hours",
        text: "Off-Peak",
        color: "#22c55e",
      })
      expect(result.lines.find((line) => line.label === "Next change")).toBeUndefined()
    })

    it("maps peak PromoClock responses into the badge-only UI", async () => {
      const ctx = makeCtx()
      ctx.host.fs.readText = () =>
        JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
      ctx.host.fs.exists = () => true
      mockClaudeUsageAndPromoClock(ctx, {
        promoClockBody: {
          ...SAMPLE_PROMOCLOCK_RESPONSE,
          status: "peak",
          isPeak: true,
          isOffPeak: false,
          emoji: "🔴",
          label: "Peak Hours — Limits Drain Faster",
          nextChange: "2026-04-08T19:00:00.000Z",
          minutesUntilChange: 111,
          timestamp: "2026-04-08T17:08:33.089Z",
          utcHour: 17,
        },
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      expect(result.lines.find((line) => line.label === "Peak Hours")?.text).toBe("Peak")
      expect(result.lines.find((line) => line.label === "Peak Hours")?.color).toBe("#ef4444")
    })

    it("treats weekend as off-peak", async () => {
      const ctx = makeCtx()
      ctx.host.fs.readText = () =>
        JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
      ctx.host.fs.exists = () => true
      mockClaudeUsageAndPromoClock(ctx, {
        promoClockBody: {
          ...SAMPLE_PROMOCLOCK_RESPONSE,
          status: "weekend",
          isPeak: false,
          isOffPeak: false,
          isWeekend: true,
          label: "Weekend — Normal Speed",
        },
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      expect(result.lines.find((line) => line.label === "Peak Hours")?.text).toBe("Off-Peak")
      expect(result.lines.find((line) => line.label === "Peak Hours")?.color).toBe("#22c55e")
    })

    it("ignores PromoClock failures and still returns Claude usage lines", async () => {
      const ctx = makeCtx()
      ctx.host.fs.readText = () =>
        JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
      ctx.host.fs.exists = () => true
      mockClaudeUsageAndPromoClock(ctx, {
        promoClockStatus: 503,
        promoClockBody: { error: "temporarily unavailable" },
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
      expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()
      expect(result.lines.find((line) => line.label === "Peak Hours")).toBeUndefined()
      expect(result.lines.find((line) => line.label === "Next change")).toBeUndefined()
    })

    it("falls back to status string when boolean flags are absent", async () => {
      const ctx = makeCtx()
      ctx.host.fs.readText = () =>
        JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
      ctx.host.fs.exists = () => true
      mockClaudeUsageAndPromoClock(ctx, {
        promoClockBody: {
          ...SAMPLE_PROMOCLOCK_RESPONSE,
          status: "off_peak",
          isPeak: undefined,
          isOffPeak: undefined,
          isWeekend: undefined,
        },
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      expect(result.lines.find((line) => line.label === "Peak Hours")?.text).toBe("Off-Peak")
      expect(result.lines.find((line) => line.label === "Peak Hours")?.color).toBe("#22c55e")
    })
  })

  it("appends max rate limit tier to the plan label when present", async () => {
    const runCase = async (rateLimitTier, expectedPlan) => {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => true
      ctx.host.fs.readText = () =>
        JSON.stringify({
          claudeAiOauth: {
            accessToken: "token",
            subscriptionType: "max",
            rateLimitTier,
          },
        })
      ctx.host.http.request.mockReturnValue({
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.plan).toBe(expectedPlan)
    }

    await runCase("claude_max_subscription_20x", "Max 20x")
    await runCase("claude_max_subscription_5x", "Max 5x")
  })

  it("omits resetsAt when resets_at is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 0 },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const sessionLine = result.lines.find((line) => line.label === "Session")
    expect(sessionLine).toBeTruthy()
    expect(sessionLine.resetsAt).toBeUndefined()
  })

  it("throws token expired on 401", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("shows rate limited badge on 429 without throwing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({ status: 429, bodyText: "", headers: {} })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const statusLine = result.lines.find((line) => line.label === "Status")
    expect(statusLine).toBeTruthy()
    expect(statusLine.text).toContain("Rate limited")
    expect(result.lines.find((line) => line.label === "Note")).toBeTruthy()
  })

  it("shows Retry-After info on 429 when header is present", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 429,
      bodyText: "",
      headers: { "Retry-After": "600" }, // 10 minutes
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const statusLine = result.lines.find((line) => line.label === "Status")
    expect(statusLine).toBeTruthy()
    expect(statusLine.text).toContain("10m")
    const noteLine = result.lines.find((line) => line.label === "Note")
    expect(noteLine).toBeTruthy()
    expect(noteLine.value).toContain("10m")
  })

  it("shows generic rate limited message when Retry-After is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({ status: 429, bodyText: "", headers: {} })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const statusLine = result.lines.find((line) => line.label === "Status")
    expect(statusLine).toBeTruthy()
    expect(statusLine.text).toContain("try again later")
  })

  it("shows retry-now when Retry-After: 0", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 429,
      bodyText: "",
      headers: { "Retry-After": "0" },
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const statusLine = result.lines.find((line) => line.label === "Status")
    expect(statusLine).toBeTruthy()
    expect(statusLine.text).toContain("~now")
    const noteLine = result.lines.find((line) => line.label === "Note")
    expect(noteLine).toBeTruthy()
    expect(noteLine.value).toContain("~now")
  })

  it("uses keychain credentials", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_sonnet: { utilization: 5, resets_at: "2099-01-01T00:00:00.000Z" },
        extra_usage: { is_enabled: true, used_credits: 250 },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Sonnet")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Extra usage spent")).toBeTruthy()
  })

  it("renders Claude Design line from seven_day_omelette with normalized resetsAt", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_omelette: { utilization: 7, resets_at: "2099-01-01 00:00:00 UTC" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines.find((l) => l.label === "Claude Design")
    expect(line).toBeTruthy()
    expect(line.used).toBe(7)
    expect(line.limit).toBe(100)
    expect(line.format).toEqual({ kind: "percent" })
    expect(line.resetsAt).toBe("2099-01-01T00:00:00.000Z")
  })

  it("omits Claude Design line when seven_day_omelette has no utilization", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_omelette: {},
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Claude Design")).toBeUndefined()
  })

  it("omits Claude Design line when seven_day_omelette utilization is non-numeric", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_omelette: { utilization: "5", resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Claude Design")).toBeUndefined()
  })

  it("omits extra usage line when used credits are zero and no limit exists", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        extra_usage: { is_enabled: true, used_credits: 0, monthly_limit: null },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Extra usage spent")).toBeUndefined()
  })

  it("uses keychain credentials when value is hex-encoded JSON", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    const json = JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } }, null, 2)
    const hex = Buffer.from(json, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 1, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("accepts 0x-prefixed hex keychain credentials", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    const json = JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } }, null, 2)
    const hex = "0x" + Buffer.from(json, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 1, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("decodes hex-encoded UTF-8 correctly (non-ascii json)", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    const json = JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pró" } }, null, 2)
    const hex = Buffer.from(json, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 1, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
  })

  it("decodes 3-byte and 4-byte UTF-8 in hex-encoded JSON", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    const json = JSON.stringify(
      { claudeAiOauth: { accessToken: "token", subscriptionType: "pro€🙂" } },
      null,
      2
    )
    const hex = Buffer.from(json, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 1, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
  })

  it("uses custom UTF-8 decoder when TextDecoder is unavailable", async () => {
    const original = globalThis.TextDecoder
    // Force plugin to use its fallback decoder.
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      const json = JSON.stringify(
        { claudeAiOauth: { accessToken: "token", subscriptionType: "pró€🙂" } },
        null,
        2
      )
      const hex = Buffer.from(json, "utf8").toString("hex")
      ctx.host.keychain.readGenericPassword.mockReturnValue(hex)
      ctx.host.http.request.mockReturnValue({
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 1, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      })
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).not.toThrow()
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("custom decoder tolerates invalid byte sequences", async () => {
    const original = globalThis.TextDecoder
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      // Invalid UTF-8 bytes (will produce replacement chars).
      ctx.host.keychain.readGenericPassword.mockReturnValue("c200ff")
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("custom decoder handles truncated 3-byte sequences in hex payloads", async () => {
    const original = globalThis.TextDecoder
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      ctx.host.keychain.readGenericPassword.mockReturnValue("e282")
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("custom decoder handles truncated 2-byte sequences in hex payloads", async () => {
    const original = globalThis.TextDecoder
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      ctx.host.keychain.readGenericPassword.mockReturnValue("c2")
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("custom decoder handles invalid 3-byte continuation sequences in hex payloads", async () => {
    const original = globalThis.TextDecoder
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      ctx.host.keychain.readGenericPassword.mockReturnValue("e228a1")
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("custom decoder handles invalid 4-byte sequences in hex payloads", async () => {
    const original = globalThis.TextDecoder
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      ctx.host.keychain.readGenericPassword.mockReturnValue("f0808080")
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("custom decoder handles truncated 4-byte sequences in hex payloads", async () => {
    const original = globalThis.TextDecoder
    // eslint-disable-next-line no-undef
    delete globalThis.TextDecoder
    try {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => false
      ctx.host.keychain.readGenericPassword.mockReturnValue("f09f98")
      const plugin = await loadPlugin()
      expect(() => plugin.probe(ctx)).toThrow("Not logged in")
    } finally {
      globalThis.TextDecoder = original
    }
  })

  it("treats invalid hex credentials as not logged in", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockReturnValue("0x123") // odd length
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws on http errors and parse failures", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValueOnce({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")

    // Reset lastUsageFetchMs so the second probe is not throttled by min-interval guard
    plugin._resetState()
    ctx.host.http.request.mockReturnValueOnce({ status: 200, bodyText: "not-json" })
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("throws on request errors", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed")
  })

  it("shows status badge when no usage data and ccusage is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({}),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((l) => l.label === "Today")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Yesterday")).toBeUndefined()
    expect(result.lines.find((l) => l.label === "Last 30 Days")).toBeUndefined()
    const statusLine = result.lines.find((l) => l.label === "Status")
    expect(statusLine).toBeTruthy()
    expect(statusLine.text).toBe("No usage data")
  })

  it("passes resetsAt through as ISO when present", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    const now = new Date("2026-02-02T00:00:00.000Z").getTime()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    const fiveHourIso = new Date(now + 30_000).toISOString()
    const sevenDayIso = new Date(now + 5 * 60_000).toISOString()
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: fiveHourIso },
        seven_day: { utilization: 20, resets_at: sevenDayIso },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")?.resetsAt).toBe(fiveHourIso)
    expect(result.lines.find((line) => line.label === "Weekly")?.resetsAt).toBe(sevenDayIso)
    nowSpy.mockRestore()
  })

  it("normalizes resets_at without timezone (microseconds) into ISO for resetsAt", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () =>
      JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "pro" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.123456" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")?.resetsAt).toBe(
      "2099-01-01T00:00:00.123Z"
    )
  })

  it("refreshes token when expired and persists updated credentials", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
          subscriptionType: "pro",
        },
      })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600, refresh_token: "refresh2" }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(ctx.host.fs.writeText).toHaveBeenCalled()
  })

  it("includes user:file_upload in the OAuth refresh scope", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
          subscriptionType: "pro",
        },
      })

    let refreshBody = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        refreshBody = JSON.parse(opts.bodyText)
        return {
          status: 200,
          bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600, refresh_token: "refresh2" }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(refreshBody.scope).toContain("user:file_upload")
  })

  it("refreshes keychain credentials and writes back to keychain", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
          subscriptionType: "pro",
        },
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return {
          status: 200,
          bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }),
        }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
    expect(ctx.host.keychain.writeGenericPassword).toHaveBeenCalled()
  })

  it("retries usage request after 401 by refreshing once", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() + 60_000,
          subscriptionType: "pro",
        },
      })

    let usageCalls = 0
    let firstUsageHeaders = null
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/oauth/usage")) {
        usageCalls += 1
        if (!firstUsageHeaders) firstUsageHeaders = opts.headers
        if (usageCalls === 1) {
          return { status: 401, bodyText: "" }
        }
        return {
          status: 200,
          bodyText: JSON.stringify({
            five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
          }),
        }
      }
      // Refresh
      return {
        status: 200,
        bodyText: JSON.stringify({ access_token: "token2", expires_in: 3600 }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(usageCalls).toBe(2)
    expect(firstUsageHeaders["User-Agent"]).toBe("claude-code/2.1.69")
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("throws session expired when refresh returns invalid_grant", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1,
        },
      })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 400, bodyText: JSON.stringify({ error: "invalid_grant" }) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws token expired when usage remains unauthorized after refresh", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() + 60_000,
        },
      })

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/oauth/usage")) {
        usageCalls += 1
        if (usageCalls === 1) return { status: 401, bodyText: "" }
        return { status: 403, bodyText: "" }
      }
      return { status: 200, bodyText: JSON.stringify({ access_token: "token2", expires_in: 3600 }) }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("throws token expired when refresh is unauthorized", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1,
        },
      })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 401, bodyText: JSON.stringify({ error: "nope" }) }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("logs when saving keychain credentials fails", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
        },
      })
    )
    ctx.host.keychain.writeGenericPassword.mockImplementation(() => {
      throw new Error("write fail")
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
    expect(ctx.host.log.error).toHaveBeenCalled()
  })

  it("writes refreshed credentials back to the current-user keychain source", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockReturnValue(
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
        },
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
    expect(ctx.host.keychain.writeGenericPasswordForCurrentUser).toHaveBeenCalled()
    expect(ctx.host.keychain.writeGenericPassword).not.toHaveBeenCalled()
  })

  it("writes refreshed credentials back to the legacy keychain source after fallback", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockImplementation(() => {
      throw new Error("keychain item not found")
    })
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
        },
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
    expect(ctx.host.keychain.writeGenericPassword).toHaveBeenCalled()
    expect(ctx.host.keychain.writeGenericPasswordForCurrentUser).not.toHaveBeenCalled()
  })

  it("logs when saving credentials file fails", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "old-token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1000,
        },
      })
    ctx.host.fs.writeText.mockImplementation(() => {
      throw new Error("disk full")
    })
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
    expect(ctx.host.log.error).toHaveBeenCalled()
  })

  it("continues when refresh request throws non-string error (returns null)", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1,
        },
      })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        throw new Error("network")
      }
      return {
        status: 200,
        bodyText: JSON.stringify({
          five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).not.toThrow()
  })

  it("falls back to keychain when file oauth exists but has no access token", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { refreshToken: "only-refresh" } })
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { accessToken: "keychain-token", subscriptionType: "pro" } })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
  })

  it("treats keychain oauth without access token as not logged in", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ claudeAiOauth: { refreshToken: "only-refresh" } })
    )
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("continues with existing token when refresh cannot return a usable token", async () => {
    const baseCreds = JSON.stringify({
      claudeAiOauth: {
        accessToken: "token",
        refreshToken: "refresh",
        expiresAt: Date.now() - 1,
      },
    })

    const runCase = async (refreshResp) => {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => true
      ctx.host.fs.readText = () => baseCreds
      ctx.host.http.request.mockImplementation((opts) => {
        if (String(opts.url).includes("/v1/oauth/token")) return refreshResp
        return {
          status: 200,
          bodyText: JSON.stringify({
            five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
          }),
        }
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    }

    await runCase({ status: 500, bodyText: "" })
    await runCase({ status: 200, bodyText: "not-json" })
    await runCase({ status: 200, bodyText: JSON.stringify({}) })
  })

  it("skips proactive refresh when token is not near expiry", async () => {
    const ctx = makeCtx()
    const now = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(now)
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: now + 24 * 60 * 60 * 1000,
          subscriptionType: "pro",
        },
      })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
    expect(
      ctx.host.http.request.mock.calls.some((call) => String(call[0]?.url).includes("/v1/oauth/token"))
    ).toBe(false)
  })

  it("handles malformed ccusage payload shape as runner_failed", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token", subscriptionType: "   " } })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
      }),
    })
    ctx.host.ccusage.query = vi.fn(() => ({ status: "ok", data: {} }))

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeNull()
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Today")).toBeUndefined()
  })

  it("throws usage request failed after refresh when retry errors", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() + 60_000,
        },
      })

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/oauth/usage")) {
        usageCalls += 1
        if (usageCalls === 1) return { status: 401, bodyText: "" }
        throw new Error("boom")
      }
      return { status: 200, bodyText: JSON.stringify({ access_token: "token2", expires_in: 3600 }) }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed after refresh")
  })

  it("throws usage request failed when retryOnceOnAuth throws a non-string error", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() + 60_000,
        },
      })

    ctx.util.retryOnceOnAuth = () => {
      throw new Error("network blew up")
    }

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("throws token expired when refresh response cannot be parsed", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      JSON.stringify({
        claudeAiOauth: {
          accessToken: "token",
          refreshToken: "refresh",
          expiresAt: Date.now() - 1,
        },
      })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/v1/oauth/token")) {
        return { status: 400, bodyText: "not-json" }
      }
      return { status: 500, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  describe("token usage: ccusage integration", () => {
    const CRED_JSON = JSON.stringify({ claudeAiOauth: { accessToken: "tok", subscriptionType: "pro" } })
    const USAGE_RESPONSE = JSON.stringify({
      five_hour: { utilization: 30, resets_at: "2099-01-01T00:00:00.000Z" },
      seven_day: { utilization: 50, resets_at: "2099-01-01T00:00:00.000Z" },
    })

    function makeProbeCtx({ ccusageResult = { status: "runner_failed" } } = {}) {
      const ctx = makeCtx()
      ctx.host.fs.exists = () => true
      ctx.host.fs.readText = () => CRED_JSON
      ctx.host.http.request.mockReturnValue({ status: 200, bodyText: USAGE_RESPONSE })
      ctx.host.ccusage.query = vi.fn(() => ccusageResult)
      return ctx
    }

    function okUsage(daily) {
      return { status: "ok", data: { daily: daily } }
    }

    function localDayKey(date) {
      const year = date.getFullYear()
      const month = String(date.getMonth() + 1).padStart(2, "0")
      const day = String(date.getDate()).padStart(2, "0")
      return year + "-" + month + "-" + day
    }

    function localCompactDayKey(date) {
      const year = String(date.getFullYear())
      const month = String(date.getMonth() + 1).padStart(2, "0")
      const day = String(date.getDate()).padStart(2, "0")
      return year + month + day
    }

    it("omits token lines when ccusage reports no_runner", async () => {
      const ctx = makeProbeCtx({ ccusageResult: { status: "no_runner" } })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((l) => l.label === "Today")).toBeUndefined()
      expect(result.lines.find((l) => l.label === "Yesterday")).toBeUndefined()
      expect(result.lines.find((l) => l.label === "Last 30 Days")).toBeUndefined()
    })

    it("rate-limit lines still appear when ccusage reports runner_failed", async () => {
      const ctx = makeProbeCtx({ ccusageResult: { status: "runner_failed" } })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
      expect(result.lines.find((l) => l.label === "Today")).toBeUndefined()
      expect(result.lines.find((l) => l.label === "Yesterday")).toBeUndefined()
    })

    it("adds Today line when ccusage returns today's data", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayKey, inputTokens: 100, outputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 150, totalCost: 0.75 },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const todayLine = result.lines.find((l) => l.label === "Today")
      expect(todayLine).toBeTruthy()
      expect(todayLine.type).toBe("text")
      expect(todayLine.value).toContain("150 tokens")
      expect(todayLine.value).toContain("$0.75")
    })

    it("adds Yesterday line when ccusage returns yesterday's data", async () => {
      const yesterday = new Date()
      yesterday.setDate(yesterday.getDate() - 1)
      const yesterdayKey = localDayKey(yesterday)
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: yesterdayKey, inputTokens: 80, outputTokens: 40, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 120, totalCost: 0.6 },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
      expect(yesterdayLine).toBeTruthy()
      expect(yesterdayLine.value).toContain("120 tokens")
      expect(yesterdayLine.value).toContain("$0.60")
    })

    it("matches locale-formatted dates for today and yesterday (regression)", async () => {
      const now = new Date()
      const monthToday = now.toLocaleString("en-US", { month: "short" })
      const dayToday = String(now.getDate()).padStart(2, "0")
      const yearToday = now.getFullYear()
      const todayLabel = monthToday + " " + dayToday + ", " + yearToday

      const yesterday = new Date(now.getTime())
      yesterday.setDate(yesterday.getDate() - 1)
      const monthYesterday = yesterday.toLocaleString("en-US", { month: "short" })
      const dayYesterday = String(yesterday.getDate()).padStart(2, "0")
      const yearYesterday = yesterday.getFullYear()
      const yesterdayLabel = monthYesterday + " " + dayYesterday + ", " + yearYesterday

      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayLabel, inputTokens: 100, outputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 150, totalCost: 0.75 },
            { date: yesterdayLabel, inputTokens: 80, outputTokens: 40, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 120, totalCost: 0.6 },
          ]),
      })

      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)

      const todayLine = result.lines.find((l) => l.label === "Today")
      expect(todayLine).toBeTruthy()
      expect(todayLine.value).toContain("150 tokens")
      expect(todayLine.value).toContain("$0.75")

      const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
      expect(yesterdayLine).toBeTruthy()
      expect(yesterdayLine.value).toContain("120 tokens")
      expect(yesterdayLine.value).toContain("$0.60")
    })

    it("matches UTC timestamp day keys at month boundary (regression)", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date(2026, 2, 1, 12, 0, 0))
      try {
        const ctx = makeProbeCtx({
          ccusageResult: okUsage([
              { date: "2026-03-01T12:00:00Z", inputTokens: 10, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 10, totalCost: 0.1 },
            ]),
        })
        const plugin = await loadPlugin()
        const result = plugin.probe(ctx)
        const todayLine = result.lines.find((l) => l.label === "Today")
        expect(todayLine).toBeTruthy()
        expect(todayLine.value).toContain("10 tokens")
      } finally {
        vi.useRealTimers()
      }
    })

    it("matches UTC+9 timestamp day keys at month boundary (regression)", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date(2026, 2, 1, 12, 0, 0))
      try {
        const ctx = makeProbeCtx({
          ccusageResult: okUsage([
              { date: "2026-03-01T00:30:00+09:00", inputTokens: 20, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 20, totalCost: 0.2 },
            ]),
        })
        const plugin = await loadPlugin()
        const result = plugin.probe(ctx)
        const todayLine = result.lines.find((l) => l.label === "Today")
        expect(todayLine).toBeTruthy()
        expect(todayLine.value).toContain("20 tokens")
      } finally {
        vi.useRealTimers()
      }
    })

    it("matches UTC-8 timestamp day keys at day boundary (regression)", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date(2026, 2, 1, 12, 0, 0))
      try {
        const ctx = makeProbeCtx({
          ccusageResult: okUsage([
              { date: "2026-03-01T23:30:00-08:00", inputTokens: 30, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 30, totalCost: 0.3 },
            ]),
        })
        const plugin = await loadPlugin()
        const result = plugin.probe(ctx)
        const todayLine = result.lines.find((l) => l.label === "Today")
        expect(todayLine).toBeTruthy()
        expect(todayLine.value).toContain("30 tokens")
      } finally {
        vi.useRealTimers()
      }
    })

    it("adds Last 30 Days line summing all daily entries", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayKey, inputTokens: 100, outputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 150, totalCost: 0.5 },
            { date: "2026-02-01", inputTokens: 200, outputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 300, totalCost: 1.0 },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const last30 = result.lines.find((l) => l.label === "Last 30 Days")
      expect(last30).toBeTruthy()
      expect(last30.value).toContain("450 tokens")
      expect(last30.value).toContain("$1.50")
    })

    it("shows empty Today/Yesterday and Last 30 Days when today has no entry", async () => {
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: "2026-02-01", inputTokens: 500, outputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 600, totalCost: 2.0 },
          ]),
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
      expect(last30.value).toContain("600 tokens")
    })

    it("shows empty Today state when ccusage returns ok with empty daily array", async () => {
      const ctx = makeProbeCtx({ ccusageResult: okUsage([]) })
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

    it("omits cost when totalCost is null", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayKey, inputTokens: 500, outputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 600, totalCost: null },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const todayLine = result.lines.find((l) => l.label === "Today")
      expect(todayLine).toBeTruthy()
      expect(todayLine.value).not.toContain("$")
      expect(todayLine.value).toContain("600 tokens")
    })

    it("shows empty Today state when today's totals are zero (regression)", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayKey, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 0, totalCost: 0 },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const todayLine = result.lines.find((l) => l.label === "Today")
      expect(todayLine).toBeTruthy()
      expect(todayLine.value).toContain("$0.00")
      expect(todayLine.value).toContain("0 tokens")
    })

    it("shows empty Yesterday state when yesterday's totals are zero (regression)", async () => {
      const yesterday = new Date()
      yesterday.setDate(yesterday.getDate() - 1)
      const yesterdayKey = localDayKey(yesterday)
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: yesterdayKey, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 0, totalCost: 0 },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const yesterdayLine = result.lines.find((l) => l.label === "Yesterday")
      expect(yesterdayLine).toBeTruthy()
      expect(yesterdayLine.value).toContain("$0.00")
      expect(yesterdayLine.value).toContain("0 tokens")
    })

    it("queries ccusage on each probe", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayKey, inputTokens: 100, outputTokens: 50, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 150, totalCost: 0.5 },
          ]),
      })
      const plugin = await loadPlugin()
      plugin.probe(ctx)
      plugin.probe(ctx)
      expect(ctx.host.ccusage.query).toHaveBeenCalledTimes(2)
    })

    it("queries ccusage with a 31-day inclusive since window", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date("2026-02-20T16:00:00.000Z"))
      try {
        const ctx = makeProbeCtx({ ccusageResult: okUsage([]) })
        const plugin = await loadPlugin()
        plugin.probe(ctx)
        expect(ctx.host.ccusage.query).toHaveBeenCalled()

        const firstCall = ctx.host.ccusage.query.mock.calls[0][0]
        const since = new Date()
        since.setDate(since.getDate() - 30)
        expect(firstCall.since).toBe(localCompactDayKey(since))
      } finally {
        vi.useRealTimers()
      }
    })

    it("matches compact day keys and falls back from invalid totalCost to costUSD", async () => {
      const today = new Date()
      const todayKey = localCompactDayKey(today)
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
          {
            date: todayKey,
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 150,
            totalCost: "not-a-number",
            costUSD: 0.25,
          },
        ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const todayLine = result.lines.find((l) => l.label === "Today")
      expect(todayLine).toBeTruthy()
      expect(todayLine.value).toContain("150 tokens")
      expect(todayLine.value).toContain("$0.25")
    })

    it("includes cache tokens in total", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
            { date: todayKey, inputTokens: 100, outputTokens: 50, cacheCreationTokens: 200, cacheReadTokens: 300, totalTokens: 650, totalCost: 1.0 },
          ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const todayLine = result.lines.find((l) => l.label === "Today")
      expect(todayLine).toBeTruthy()
      expect(todayLine.value).toContain("650 tokens")
    })

    it("formats compact token values with decimal and rounded K suffixes", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
          {
            date: todayKey,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 1500,
            totalCost: 0.5,
          },
          {
            date: "2026-02-01",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 10500,
            totalCost: 1.5,
          },
        ]),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      const todayLine = result.lines.find((l) => l.label === "Today")
      const last30 = result.lines.find((l) => l.label === "Last 30 Days")
      expect(todayLine.value).toContain("1.5K tokens")
      expect(last30.value).toContain("12K tokens")
    })

    it("shows rate limited status after all retries exhausted", async () => {
      const todayKey = localDayKey(new Date())
      const ctx = makeProbeCtx({
        ccusageResult: okUsage([
          { date: todayKey, inputTokens: 100, outputTokens: 50, totalTokens: 150, totalCost: 0.25 },
        ]),
      })
      // All calls return 429
      ctx.host.http.request.mockReturnValue({
        status: 429,
        bodyText: '{"error":"rate limited"}',
        headers: { "Retry-After": "1200" }, // 20 minutes
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((line) => line.label === "Today")).toBeTruthy()
      const statusLine = result.lines.find((line) => line.label === "Status")
      expect(statusLine).toBeTruthy()
      expect(statusLine.text).toContain("20m")
      const noteLine = result.lines.find((line) => line.label === "Note")
      expect(noteLine).toBeTruthy()
      expect(noteLine.value).toContain("20m")
    })
  })

  describe("rate limiting (429)", () => {
    it("parses Retry-After HTTP-date header", async () => {
      // Freeze time so HTTP-date parsing is deterministic
      const frozenNow = new Date("2026-04-14T10:00:00.000Z")
      vi.useFakeTimers()
      vi.setSystemTime(frozenNow)
      try {
        const ctx = makeCtx()
        ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
        ctx.host.fs.exists = () => true
        // 15 minutes after frozenNow → expect "~15m"
        ctx.host.http.request.mockReturnValue({
          status: 429,
          bodyText: "",
          headers: { "Retry-After": "Mon, 14 Apr 2026 10:15:00 GMT" },
        })
        const plugin = await loadPlugin()
        const result = plugin.probe(ctx)
        const noteLine = result.lines.find((line) => line.label === "Note")
        expect(noteLine).toBeTruthy()
        expect(noteLine.value).toBe("Live usage rate limited — retry in ~15m")
      } finally {
        vi.useRealTimers()
      }
    })

    it("does not call API again while rate-limit window is active", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date("2026-04-14T10:00:00.000Z"))
      try {
        const ctx = makeCtx()
        ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
        ctx.host.fs.exists = () => true
        // Isolate Promoclock so it doesn't add extra calls to ctx.host.http.request
        ctx.util.requestJson = vi.fn(() => ({ resp: { status: 200, bodyText: "{}", headers: {} }, json: {} }))
        ctx.host.http.request.mockReturnValue({
          status: 429,
          bodyText: "",
          headers: { "Retry-After": "300" }, // 5 minutes
        })
        const plugin = await loadPlugin()

        // First probe — gets 429, stores rateLimitedUntilMs
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1)

        // Second probe 60 s later — still within window, must NOT call API
        vi.setSystemTime(new Date("2026-04-14T10:01:00.000Z"))
        const result2 = plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1) // no new request
        const statusLine = result2.lines.find((l) => l.label === "Status")
        expect(statusLine).toBeTruthy()
        expect(statusLine.text).toMatch(/4m/) // ~4 minutes remaining
      } finally {
        vi.useRealTimers()
      }
    })

    it("resumes API calls after rate-limit window expires", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date("2026-04-14T10:00:00.000Z"))
      try {
        const ctx = makeCtx()
        ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
        ctx.host.fs.exists = () => true
        // Isolate Promoclock so it doesn't add extra calls to ctx.host.http.request
        ctx.util.requestJson = vi.fn(() => ({ resp: { status: 200, bodyText: "{}", headers: {} }, json: {} }))
        const usageBody = JSON.stringify({ five_hour: { utilization: 50, resets_at: null } })
        ctx.host.http.request
          .mockReturnValueOnce({ status: 429, bodyText: "", headers: { "Retry-After": "60" } })
          .mockReturnValue({ status: 200, bodyText: usageBody, headers: {} })
        const plugin = await loadPlugin()

        // First probe → 429
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1)

        // 90 s later — window expired, should attempt API again
        vi.setSystemTime(new Date("2026-04-14T10:01:30.000Z"))
        const result2 = plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(2)
        // No rate-limited badge after success (amber color = rate-limited)
        expect(result2.lines.find((l) => l.label === "Status" && l.color === "#f59e0b")).toBeUndefined()
      } finally {
        vi.useRealTimers()
      }
    })

    it("skips API call when minimum fetch interval has not elapsed", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date("2026-04-14T10:00:00.000Z"))
      try {
        const ctx = makeCtx()
        ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
        ctx.host.fs.exists = () => true
        // Isolate Promoclock so it doesn't add extra calls to ctx.host.http.request
        ctx.util.requestJson = vi.fn(() => ({ resp: { status: 200, bodyText: "{}", headers: {} }, json: {} }))
        ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "{}", headers: {} })
        const plugin = await loadPlugin()

        // First probe — succeeds
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1)

        // 30 s later — within MIN_USAGE_FETCH_INTERVAL_MS (5 min), no new request
        vi.setSystemTime(new Date("2026-04-14T10:00:30.000Z"))
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1)

        // 5+ minutes later — interval elapsed, should fetch again
        vi.setSystemTime(new Date("2026-04-14T10:05:01.000Z"))
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(2)
      } finally {
        vi.useRealTimers()
      }
    })

    it("shows cached plan data while rate-limited", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date("2026-04-14T10:00:00.000Z"))
      try {
        const successBody = JSON.stringify({
          five_hour: { utilization: 42, resets_at: null },
        })
        const ctx = makeCtx()
        ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
        ctx.host.fs.exists = () => true
        ctx.host.http.request
          .mockReturnValueOnce({ status: 200, bodyText: successBody, headers: {} })
          .mockReturnValue({ status: 429, bodyText: "", headers: { "Retry-After": "300" } })
        const plugin = await loadPlugin()

        // First probe succeeds → data cached
        const result1 = plugin.probe(ctx)
        expect(result1.lines.find((l) => l.label === "Session")).toBeTruthy()

        // Second probe — 429, but cached data is shown alongside rate-limit badge
        vi.setSystemTime(new Date("2026-04-14T10:05:01.000Z")) // past min interval
        const result2 = plugin.probe(ctx)
        expect(result2.lines.find((l) => l.label === "Session")).toBeTruthy()
        expect(result2.lines.find((l) => l.label === "Status")).toBeTruthy()
      } finally {
        vi.useRealTimers()
      }
    })

    it("uses default 5-minute backoff when no Retry-After header on 429", async () => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date("2026-04-14T10:00:00.000Z"))
      try {
        const ctx = makeCtx()
        ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
        ctx.host.fs.exists = () => true
        // Isolate Promoclock so it doesn't add extra calls to ctx.host.http.request
        ctx.util.requestJson = vi.fn(() => ({ resp: { status: 200, bodyText: "{}", headers: {} }, json: {} }))
        ctx.host.http.request
          .mockReturnValueOnce({ status: 429, bodyText: "", headers: {} }) // no Retry-After
          .mockReturnValue({ status: 200, bodyText: "{}", headers: {} })
        const plugin = await loadPlugin()

        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1)

        // 4 min 59 s later — default 5 min backoff still active
        vi.setSystemTime(new Date("2026-04-14T10:04:59.000Z"))
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(1)

        // 5 min 1 s later — backoff expired
        vi.setSystemTime(new Date("2026-04-14T10:05:01.000Z"))
        plugin.probe(ctx)
        expect(ctx.host.http.request).toHaveBeenCalledTimes(2)
      } finally {
        vi.useRealTimers()
      }
    })
  })
})
