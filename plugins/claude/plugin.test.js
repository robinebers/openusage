import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

describe("claude plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

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
    expect(result.plan).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Session")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly")).toBeTruthy()
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
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("/api/oauth/usage")) {
        usageCalls += 1
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

      delete globalThis.__openusage_plugin
      vi.resetModules()
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
  })
})
