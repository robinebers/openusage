import { beforeEach, describe, expect, it, vi } from "vitest"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const makeCtx = () => {
  const files = new Map()
  return {
    nowIso: "2026-02-02T00:00:00.000Z",
    host: {
      fs: {
        exists: (path) => files.has(path),
        readText: (path) => files.get(path),
        writeText: (path, text) => files.set(path, text),
      },
      http: {
        request: vi.fn(),
      },
    },
    line: {
      text: (label, value, color) => {
        const line = { type: "text", label, value }
        if (color) line.color = color
        return line
      },
      progress: (label, value, max, unit, color) => {
        const line = { type: "progress", label, value, max }
        if (unit) line.unit = unit
        if (color) line.color = color
        return line
      },
      badge: (label, text, color) => {
        const line = { type: "badge", label, text }
        if (color) line.color = color
        return line
      },
    },
    fmt: {
      planLabel: (value) => {
        const text = String(value || "").trim()
        if (!text) return ""
        return text.replace(/(^|\s)([a-z])/g, (match, space, letter) => space + letter.toUpperCase())
      },
      resetIn: (secondsUntil) => {
        if (!Number.isFinite(secondsUntil) || secondsUntil < 0) return null
        const totalMinutes = Math.floor(secondsUntil / 60)
        const totalHours = Math.floor(totalMinutes / 60)
        const days = Math.floor(totalHours / 24)
        const hours = totalHours % 24
        const minutes = totalMinutes % 60
        if (days > 0) return `${days}d ${hours}h`
        if (totalHours > 0) return `${totalHours}h ${minutes}m`
        if (totalMinutes > 0) return `${totalMinutes}m`
        return "<1m"
      },
      dollars: (cents) => Math.round((cents / 100) * 100) / 100,
      date: (unixMs) => {
        const d = new Date(Number(unixMs))
        const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return months[d.getMonth()] + " " + String(d.getDate())
      },
    },
  }
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

  it("throws when auth json is invalid", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.codex/auth.json", "{bad")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
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
    expect(result.lines.find((line) => line.label === "Plan")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Session (5h)")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly (7d)")).toBeTruthy()
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
    expect(result.lines.find((line) => line.label === "Session (5h)")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Reviews (7d)")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Credits")).toBeTruthy()
  })

  it("skips reset lines when window lacks reset info", async () => {
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
    expect(result.lines.find((line) => line.label === "Session (5h)")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Resets in")).toBeFalsy()
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
