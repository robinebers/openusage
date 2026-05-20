import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const LOAD_CODE_ASSIST_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
const FETCH_MODELS_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
const RETRIEVE_QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
const LOGIN_MESSAGE = "Not logged in. Run `agy` and complete Google sign-in first."

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function setKeychain(ctx, value) {
  ctx.host.keychain.readGenericPassword.mockImplementation((service, account) => {
    if (service === "gemini" && account === "antigravity") return value
    return null
  })
}

function mockResponses(ctx, responses) {
  ctx.host.http.request.mockImplementation((opts) => {
    const url = String(opts.url)
    if (!responses[url]) throw new Error("unexpected url: " + url)
    return responses[url](opts)
  })
}

function json(status, body) {
  return { status, bodyText: JSON.stringify(body) }
}

describe("antigravity-cli plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("loads a raw keychain bearer token and parses fetchAvailableModels quotaInfo", async () => {
    const ctx = makeCtx()
    setKeychain(ctx, "Bearer raw-token")
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => json(200, { userTier: { name: "Google AI Ultra" } }),
      [FETCH_MODELS_URL]: (opts) => {
        expect(opts.headers.Authorization).toBe("Bearer raw-token")
        return json(200, {
          models: {
            proHigh: {
              displayName: "Gemini 3 Pro (High)",
              model: "gemini-3-pro",
              quotaInfo: { remainingFraction: 0.4, resetTime: "2026-05-21T00:00:00Z" },
            },
            proLow: {
              displayName: "Gemini 3 Pro (Low)",
              model: "gemini-3-pro-low",
              quotaInfo: { remainingFraction: 0.9 },
            },
            flash: {
              displayName: "Gemini Flash",
              model: "gemini-3-flash",
              quotaInfo: { remainingFraction: 0.8 },
            },
            claude: {
              displayName: "Claude Sonnet",
              model: "claude-sonnet",
              quotaInfo: { remainingFraction: 0.25 },
            },
          },
        })
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(plugin.id).toBe("antigravity-cli")
    expect(result.plan).toBe("Google AI Ultra")
    expect(result.lines.map((line) => line.label)).toEqual(["Gemini Pro", "Gemini Flash", "Claude"])
    expect(result.lines.find((line) => line.label === "Gemini Pro").used).toBe(60)
    expect(result.lines.find((line) => line.label === "Gemini Flash").used).toBe(20)
    expect(result.lines.find((line) => line.label === "Claude").used).toBe(75)
    expect(ctx.host.http.request).toHaveBeenCalledTimes(2)
  })

  it("loads an OAuth-style JSON keychain token", async () => {
    const ctx = makeCtx()
    setKeychain(ctx, JSON.stringify({ access_token: "json-token", refresh_token: "refresh" }))
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => json(200, {}),
      [FETCH_MODELS_URL]: (opts) => {
        expect(opts.headers.Authorization).toBe("Bearer json-token")
        return json(200, {
          models: [{ label: "Gemini Pro", quotaInfo: { remainingFraction: 1 } }],
        })
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBeUndefined()
    expect(result.lines.find((line) => line.label === "Gemini Pro").used).toBe(0)
  })

  it("loads a go-keyring-base64 wrapped JSON token", async () => {
    const ctx = makeCtx()
    const encoded = ctx.base64.encode(JSON.stringify({ tokens: { accessToken: "wrapped-token" } }))
    setKeychain(ctx, "go-keyring-base64:" + encoded)
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => json(200, {}),
      [FETCH_MODELS_URL]: (opts) => {
        expect(opts.headers.Authorization).toBe("Bearer wrapped-token")
        return json(200, {
          models: [{ label: "Gemini Flash", model: "gemini-flash", quotaInfo: { remainingFraction: 0.55 } }],
        })
      },
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Gemini Flash").used).toBe(45)
  })

  it("throws agy login instruction when keychain entry is missing", async () => {
    const ctx = makeCtx()
    setKeychain(ctx, null)
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(LOGIN_MESSAGE)
    expect(ctx.host.http.request).not.toHaveBeenCalled()
  })

  it("falls back to retrieveUserQuota nested buckets when fetchAvailableModels lacks quota", async () => {
    const ctx = makeCtx()
    setKeychain(ctx, "token")
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => json(200, { user: { tier: { name: "Ignored" } } }),
      [FETCH_MODELS_URL]: () => json(200, { models: [{ displayName: "Gemini Pro", model: "gemini-pro" }] }),
      [RETRIEVE_QUOTA_URL]: () => json(200, {
        quota: {
          pools: {
            gemini_pro: {
              buckets: [
                { modelId: "gemini-3-pro", remainingFraction: 0.7 },
                { modelId: "gemini-3-pro-high", remainingFraction: 0.2 },
              ],
            },
            gemini_flash: {
              buckets: [{ model_id: "gemini-3-flash", remainingFraction: 0.6 }],
            },
            third_party: {
              claude: [{ modelId: "claude-sonnet", remainingFraction: 0.3 }],
            },
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Gemini Pro").used).toBe(80)
    expect(result.lines.find((line) => line.label === "Gemini Flash").used).toBe(40)
    expect(result.lines.find((line) => line.label === "Claude").used).toBe(70)
    expect(ctx.host.http.request).toHaveBeenCalledTimes(3)
  })

  it("returns no quota badge for missing or empty quota responses", async () => {
    const ctx = makeCtx()
    setKeychain(ctx, "token")
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => json(200, {}),
      [FETCH_MODELS_URL]: () => json(200, { models: [] }),
      [RETRIEVE_QUOTA_URL]: () => json(200, { quota: { pools: [] } }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines).toEqual([expect.objectContaining({ type: "badge", label: "Status", text: "No quota data" })])
  })

  it("throws agy login instruction on auth failure", async () => {
    const ctx = makeCtx()
    setKeychain(ctx, "expired")
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => ({ status: 401, bodyText: "{}" }),
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow(LOGIN_MESSAGE)
  })

  it("does not read legacy Gemini OAuth files", async () => {
    const ctx = makeCtx()
    const existsCalls = []
    const readCalls = []
    ctx.host.fs.exists = (path) => {
      existsCalls.push(path)
      if (
        path === "~/.gemini/settings.json" ||
        path === "~/.gemini/oauth_creds.json" ||
        String(path).includes("@google/gemini-cli")
      ) {
        throw new Error("legacy Gemini path touched: " + path)
      }
      return path === "~/.gemini/antigravity-cli"
    }
    ctx.host.fs.readText = (path) => {
      readCalls.push(path)
      throw new Error("unexpected readText: " + path)
    }
    setKeychain(ctx, "token")
    mockResponses(ctx, {
      [LOAD_CODE_ASSIST_URL]: () => json(200, {}),
      [FETCH_MODELS_URL]: () => json(200, {
        models: [{ label: "Gemini Pro", model: "gemini-pro", quotaInfo: { remainingFraction: 0.5 } }],
      }),
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(readCalls).not.toContain("~/.gemini/oauth_creds.json")
    expect(existsCalls).toContain("~/.gemini/antigravity-cli")
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("gemini", "antigravity")
  })
})
