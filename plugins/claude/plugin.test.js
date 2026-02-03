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
    expect(result.lines.find((line) => line.label === "Extra usage")).toBeTruthy()
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

  it("returns status when no usage data", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({}),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("No usage data")
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
})
