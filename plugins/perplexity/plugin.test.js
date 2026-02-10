import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const PREFS_PATH = "~/Library/Containers/ai.perplexity.mac/Data/Library/Preferences/ai.perplexity.mac.plist"
const BASELINE_STATE_PATH = "/tmp/openusage-test/plugin/usage-baseline.json"

const loadPlugin = async () => {
  if (!globalThis.__openusage_plugin) {
    await import("./plugin.js")
  }
  return globalThis.__openusage_plugin
}

function makePrefsBlob(overrides = {}) {
  const user = {
    isOrganizationAdmin: false,
    subscription: {
      source: "none",
      tier: "none",
      paymentTier: "none",
      status: "none",
    },
    remainingUsage: { remaining_pro: 2, remaining_research: 1, remaining_labs: 0 },
    disabledBackendModels: [],
    ...overrides,
  }
  const token =
    overrides.authToken ||
    "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
  return [
    "authToken",
    token,
    JSON.stringify(user),
  ].join("\n")
}

function makePrefsBlobWithBase64User(overrides = {}) {
  const user = {
    subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
    queryCount: 2,
    remainingUsage: { remaining_pro: 1, remaining_research: 0, remaining_labs: 0 },
    ...overrides,
  }
  const encoded = Buffer.from(JSON.stringify(user), "utf8").toString("base64")
  return [
    "authToken",
    "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl",
    "current_user__data",
    encoded,
  ].join("\n")
}

function makeRequestHexWithBearer(token) {
  return Buffer.from("Authorization: Bearer " + token + "\n", "utf8").toString("hex")
}

describe("perplexity plugin", () => {
  beforeEach(() => {
    if (vi.resetModules) vi.resetModules()
  })

  it("throws when no credentials are available", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when credentials are unreadable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "not-a-token"
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("uses fallback auth token from cache request hex", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = (path) => path.includes("Cache.db")
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (String(sql).includes("hex(b.request_object)")) {
        return JSON.stringify([
          { requestHex: makeRequestHexWithBearer("eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..a.b.c.d") },
        ])
      }
      if (String(sql).includes("CAST(r.receiver_data AS TEXT)")) {
        return JSON.stringify([])
      }
      return JSON.stringify([])
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        remaining_pro: 1,
        pro_limit: 5,
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Pro")?.type).toBe("progress")
  })

  it("does not treat cached snapshot as authenticated when token is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = (path) =>
      path.includes("Cache.db")
    ctx.host.fs.readText = () => {
      throw new Error("invalid utf-8")
    }
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (String(sql).includes("hex(b.request_object)")) return JSON.stringify([])
      if (String(sql).includes("CAST(r.receiver_data AS TEXT)")) {
        return JSON.stringify([
          {
            body: JSON.stringify({
              subscription_tier: "pro",
              remainingUsage: { remaining_pro: 2, pro_limit: 10 },
            }),
          },
        ])
      }
      return JSON.stringify([])
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("uses v5.1 snapshot usage even when auth token cannot be parsed", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      id: "u_123",
      subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
      queryCount: 4,
      uploadLimit: 6,
      remainingUsage: { remaining_pro: 2, remaining_research: 0, remaining_labs: 0 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "token-not-jwt-format"
      if (key === "current_user__data") return encoded
      return ""
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(pro.type).toBe("progress")
    expect(pro.used).toBe(4)
    expect(pro.limit).toBe(6)
    expect(result.plan).toBe("Free")
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })

  it("parses usage payload into progress lines", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      makePrefsBlob({
        remainingUsage: {},
      })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        remainingUsage: {
          remaining_pro: 2,
          pro_limit: 10,
          pro_resets_at: "2099-01-01T00:00:00Z",
        },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(pro.type).toBe("progress")
    expect(pro.used).toBe(8)
    expect(pro.limit).toBe(10)
    expect(pro.resetsAt).toBe("2099-01-01T00:00:00.000Z")
  })

  it("uses local snapshot and skips remote request when available", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => makePrefsBlob()
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })

  it("throws token expired on auth errors when local snapshot is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "authToken\neyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl\n"
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("does not show token expired when local session exists but usage is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      id: "u_123",
      subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
      remainingUsage: {},
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage data unavailable")
  })

  it("shows usage unavailable when local signed-in snapshot exists but token is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      id: "u_123",
      email: "user@example.com",
      subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
      remainingUsage: {},
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return ""
      if (key === "current_user__data") return encoded
      return ""
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage data unavailable")
  })

  it("throws token expired on 403 when local snapshot is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "authToken\neyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl\n"
    ctx.host.http.request.mockReturnValue({ status: 403, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("throws on network request errors when local usage is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "authToken\neyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl\n"
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("network down")
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("throws on non-auth http errors when local snapshot is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      makePrefsBlob({
        remainingUsage: {},
      })
    ctx.host.http.request.mockReturnValue({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on invalid json responses when local snapshot is unavailable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      makePrefsBlob({
        remainingUsage: {},
      })
    ctx.host.http.request.mockReturnValue({ status: 200, bodyText: "not-json" })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("throws when quota fields are missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      makePrefsBlob({
        remainingUsage: {},
      })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        subscription_tier: "pro",
      }),
    })
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage data unavailable")
  })

  it("renders zero-left metric lines when remaining values are zero and caps are not inferable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      id: "u_123",
      email: "user@example.com",
      subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
      remainingUsage: { remaining_pro: 0, remaining_research: 0, remaining_labs: 0 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return ""
      if (key === "current_user__data") return encoded
      return ""
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines).toEqual(
      expect.arrayContaining([
        { type: "text", label: "Pro", value: "0 left" },
        { type: "text", label: "Research", value: "0 left" },
        { type: "text", label: "Labs", value: "0 left" },
      ])
    )
  })

  it("does not use API key env fallback", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => makePrefsBlob()
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        remainingUsage: { remaining_pro: 1, pro_limit: 2 },
      }),
    })
    const plugin = await loadPlugin()
    plugin.probe(ctx)
    expect(ctx.host.env.get).not.toHaveBeenCalled()
  })

  it("uses prefs snapshot usage when endpoint payload omits remaining fields", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      makePrefsBlob({
        remainingUsage: { remaining_pro: 3, pro_limit: 10 },
      })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ subscription_tier: "pro" }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(7)
    expect(pro.limit).toBe(10)
  })

  it("parses v5.1 base64 current_user snapshot from prefs", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
      queryCount: 2,
      uploadLimit: 3,
      remainingUsage: { remaining_pro: 1, remaining_research: 0, remaining_labs: 0 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({ subscription_tier: "none" }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(pro.type).toBe("progress")
    expect(pro.used).toBe(2)
    expect(pro.limit).toBe(3)
  })

  it("does not use queryCount to compute limit when uploadLimit exists", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      subscription: { tier: "none", status: "none", paymentTier: "none", source: "none" },
      queryCount: 99,
      uploadLimit: 3,
      remainingUsage: { remaining_pro: 1, remaining_research: 0, remaining_labs: 0 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(pro.used).toBe(2)
    expect(pro.limit).toBe(3)
  })

  it("shows zero-used progress bars when pro-tier remaining values exist without explicit limits", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      subscription: { tier: "pro", status: "active", paymentTier: "unknown", source: "stripe" },
      uploadLimit: 50,
      remainingUsage: { remaining_pro: 600, remaining_research: 20, remaining_labs: 25 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const pro = result.lines.find((line) => line.label === "Pro")
    const research = result.lines.find((line) => line.label === "Research")
    const labs = result.lines.find((line) => line.label === "Labs")
    expect(result.plan).toBe("Pro")
    expect(pro).toBeTruthy()
    expect(pro.type).toBe("progress")
    expect(pro.used).toBe(0)
    expect(pro.limit).toBe(600)
    expect(research?.type).toBe("progress")
    expect(research?.used).toBe(0)
    expect(research?.limit).toBe(20)
    expect(labs?.type).toBe("progress")
    expect(labs?.used).toBe(0)
    expect(labs?.limit).toBe(25)
  })

  it("infers used values from cached high-water remaining when explicit limits are missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = (path) =>
      path.includes("Cache.db") || path.includes("ai.perplexity.mac.plist")
    ctx.host.fs.readText = () => ""
    const snapshot = {
      subscription: { tier: "pro", status: "active", paymentTier: "unknown", source: "stripe" },
      remainingUsage: { remaining_pro: 599, remaining_research: 17, remaining_labs: 25 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    ctx.host.sqlite.query.mockImplementation((_dbPath, sql) => {
      if (String(sql).includes("CAST(r.receiver_data AS TEXT)")) {
        return JSON.stringify([
          {
            body: JSON.stringify({
              remainingUsage: {
                remaining_pro: 600,
                remaining_research: 20,
                remaining_labs: 25,
              },
            }),
          },
        ])
      }
      return JSON.stringify([])
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const pro = result.lines.find((line) => line.label === "Pro")
    const research = result.lines.find((line) => line.label === "Research")
    const labs = result.lines.find((line) => line.label === "Labs")

    expect(pro?.type).toBe("progress")
    expect(pro?.used).toBe(1)
    expect(pro?.limit).toBe(600)

    expect(research?.type).toBe("progress")
    expect(research?.used).toBe(3)
    expect(research?.limit).toBe(20)

    expect(labs?.type).toBe("progress")
    expect(labs?.used).toBe(0)
    expect(labs?.limit).toBe(25)
  })

  it("tracks remaining-only usage across probes using persisted baseline state", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(PREFS_PATH, "prefs")
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))

    let remainingResearch = 20
    const token = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return token
      if (key === "current_user__data") {
        const snapshot = {
          id: "u_123",
          email: "user@example.com",
          subscription: { tier: "pro", status: "active", paymentTier: "pro", source: "stripe" },
          remainingUsage: { remaining_pro: 600, remaining_research: remainingResearch, remaining_labs: 25 },
        }
        return Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
      }
      return ""
    })

    const plugin = await loadPlugin()

    const first = plugin.probe(ctx)
    const firstResearch = first.lines.find((line) => line.label === "Research")
    expect(firstResearch?.type).toBe("progress")
    expect(firstResearch?.used).toBe(0)
    expect(firstResearch?.limit).toBe(20)

    remainingResearch = 17
    const second = plugin.probe(ctx)
    const secondResearch = second.lines.find((line) => line.label === "Research")
    expect(secondResearch?.type).toBe("progress")
    expect(secondResearch?.used).toBe(3)
    expect(secondResearch?.limit).toBe(20)

    const baselineText = ctx.host.fs.readText(BASELINE_STATE_PATH)
    const baseline = JSON.parse(baselineText)
    expect(baseline.metrics.research.baselineRemaining).toBe(20)
    expect(baseline.metrics.research.lastRemaining).toBe(17)
  })

  it("raises persisted baseline when remaining increases", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(PREFS_PATH, "prefs")
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))

    let remainingPro = 599
    const token = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return token
      if (key === "current_user__data") {
        const snapshot = {
          id: "u_123",
          email: "user@example.com",
          subscription: { tier: "pro", status: "active", paymentTier: "pro", source: "stripe" },
          remainingUsage: { remaining_pro: remainingPro, remaining_research: 20, remaining_labs: 25 },
        }
        return Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
      }
      return ""
    })

    const plugin = await loadPlugin()

    const first = plugin.probe(ctx)
    const firstPro = first.lines.find((line) => line.label === "Pro")
    expect(firstPro?.type).toBe("progress")
    expect(firstPro?.used).toBe(1)
    expect(firstPro?.limit).toBe(600)

    remainingPro = 600
    const second = plugin.probe(ctx)
    const secondPro = second.lines.find((line) => line.label === "Pro")
    expect(secondPro?.type).toBe("progress")
    expect(secondPro?.used).toBe(0)
    expect(secondPro?.limit).toBe(600)

    const baselineText = ctx.host.fs.readText(BASELINE_STATE_PATH)
    const baseline = JSON.parse(baselineText)
    expect(baseline.metrics.pro.baselineRemaining).toBe(600)
    expect(baseline.metrics.pro.lastRemaining).toBe(600)
  })

  it("uses pro-tier default caps when persisted baseline is stale low", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(PREFS_PATH, "prefs")
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))
    ctx.host.fs.writeText(
      BASELINE_STATE_PATH,
      JSON.stringify({
        version: 1,
        accountKey: "u_123",
        planTier: "pro",
        metrics: {
          pro: { baselineRemaining: 600, lastRemaining: 600, updatedAt: "2026-02-02T00:00:00.000Z" },
          research: { baselineRemaining: 17, lastRemaining: 17, updatedAt: "2026-02-02T00:00:00.000Z" },
          labs: { baselineRemaining: 25, lastRemaining: 25, updatedAt: "2026-02-02T00:00:00.000Z" },
        },
      })
    )

    const token = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return token
      if (key === "current_user__data") {
        const snapshot = {
          id: "u_123",
          email: "user@example.com",
          subscription: { tier: "pro", status: "active", paymentTier: "pro", source: "stripe" },
          remainingUsage: { remaining_pro: 600, remaining_research: 17, remaining_labs: 25 },
        }
        return Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
      }
      return ""
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const research = result.lines.find((line) => line.label === "Research")
    expect(research?.type).toBe("progress")
    expect(research?.used).toBe(3)
    expect(research?.limit).toBe(20)
  })

  it("resets persisted baselines when account identity changes", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(PREFS_PATH, "prefs")
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))

    let accountId = "u_123"
    let remainingResearch = 20
    const token = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return token
      if (key === "current_user__data") {
        const snapshot = {
          id: accountId,
          email: accountId + "@example.com",
          subscription: { tier: "pro", status: "active", paymentTier: "pro", source: "stripe" },
          remainingUsage: { remaining_pro: 600, remaining_research: remainingResearch, remaining_labs: 25 },
        }
        return Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
      }
      return ""
    })

    const plugin = await loadPlugin()

    plugin.probe(ctx)
    remainingResearch = 17
    const sameAccount = plugin.probe(ctx)
    const sameAccountResearch = sameAccount.lines.find((line) => line.label === "Research")
    expect(sameAccountResearch?.used).toBe(3)
    expect(sameAccountResearch?.limit).toBe(20)

    accountId = "u_999"
    remainingResearch = 20
    const switchedAccount = plugin.probe(ctx)
    const switchedResearch = switchedAccount.lines.find((line) => line.label === "Research")
    expect(switchedResearch?.used).toBe(0)
    expect(switchedResearch?.limit).toBe(20)
  })

  it("resets persisted baselines when plan tier changes", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(PREFS_PATH, "prefs")
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([]))

    let tier = "pro"
    let remainingResearch = 20
    const token = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return token
      if (key === "current_user__data") {
        const snapshot = {
          id: "u_123",
          email: "user@example.com",
          subscription: { tier, status: "active", paymentTier: tier, source: "stripe" },
          remainingUsage: { remaining_pro: 600, remaining_research: remainingResearch, remaining_labs: 25 },
        }
        return Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
      }
      return ""
    })

    const plugin = await loadPlugin()

    plugin.probe(ctx)
    remainingResearch = 17
    const proTier = plugin.probe(ctx)
    const proTierResearch = proTier.lines.find((line) => line.label === "Research")
    expect(proTierResearch?.used).toBe(3)
    expect(proTierResearch?.limit).toBe(20)

    tier = "none"
    remainingResearch = 2
    const freeTier = plugin.probe(ctx)
    const freeTierResearch = freeTier.lines.find((line) => line.label === "Research")
    expect(freeTierResearch?.used).toBe(0)
    expect(freeTierResearch?.limit).toBe(2)
  })

  it("uses explicit pro limit over uploadLimit for pro-tier accounts", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      subscription: { tier: "pro", status: "active", paymentTier: "unknown", source: "stripe" },
      uploadLimit: 50,
      remainingUsage: { remaining_pro: 600, pro_limit: 1000 },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(pro).toBeTruthy()
    expect(pro.type).toBe("progress")
    expect(pro.used).toBe(400)
    expect(pro.limit).toBe(1000)
  })

  it("sets plan when subscription tier is available", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () =>
      makePrefsBlob({
        remainingUsage: {},
      })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        subscription_tier: "pro",
        remainingUsage: { remaining_pro: 0, pro_limit: 2 },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Pro")
  })

  it("parses premium-like snapshot tiers (Pro, Research, Labs) with reset timestamps", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => ""
    const snapshot = {
      id: "u_123",
      subscription: { tier: "pro", status: "active", paymentTier: "pro", source: "stripe" },
      remainingUsage: {
        remaining_pro: 3,
        pro_limit: 10,
        pro_resets_at: "2099-01-01T00:00:00Z",
        remaining_research: 2,
        research_limit: 5,
        research_resets_at: "2099-02-01T00:00:00Z",
        remaining_labs: 1,
        labs_limit: 4,
        labs_resets_at: "2099-03-01T00:00:00Z",
      },
    }
    const encoded = Buffer.from(JSON.stringify(snapshot), "utf8").toString("base64")
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      if (key === "current_user__data") return encoded
      return ""
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Pro")

    const pro = result.lines.find((line) => line.label === "Pro")
    const research = result.lines.find((line) => line.label === "Research")
    const labs = result.lines.find((line) => line.label === "Labs")

    expect(pro?.type).toBe("progress")
    expect(research?.type).toBe("progress")
    expect(labs?.type).toBe("progress")

    expect(pro?.used).toBe(7)
    expect(pro?.limit).toBe(10)
    expect(pro?.resetsAt).toBe("2099-01-01T00:00:00.000Z")

    expect(research?.used).toBe(3)
    expect(research?.limit).toBe(5)
    expect(research?.resetsAt).toBe("2099-02-01T00:00:00.000Z")

    expect(labs?.used).toBe(3)
    expect(labs?.limit).toBe(4)
    expect(labs?.resetsAt).toBe("2099-03-01T00:00:00.000Z")
  })

  it("uses cached premium-like user usage before remote request", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = (path) => path.includes("Cache.db") || path.includes("ai.perplexity.mac.plist")
    ctx.host.fs.readText = () => ""
    ctx.host.plist.readRaw.mockImplementation((_path, key) => {
      if (key === "authToken") return "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..abc.def.ghi.jkl"
      return ""
    })
    ctx.host.sqlite.query.mockImplementation((dbPath, sql) => {
      if (String(sql).includes("CAST(r.receiver_data AS TEXT)")) {
        return JSON.stringify([
          {
            body: JSON.stringify({
              id: "u_123",
              subscription_tier: "pro",
              remainingUsage: {
                remaining_pro: 2,
                pro_limit: 5,
              },
            }),
          },
        ])
      }
      return JSON.stringify([])
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const pro = result.lines.find((line) => line.label === "Pro")
    expect(result.plan).toBe("Pro")
    expect(pro?.used).toBe(3)
    expect(pro?.limit).toBe(5)
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })
})
