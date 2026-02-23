import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const SETTINGS_PATH = "~/.gemini/settings.json"
const CREDS_PATH = "~/.gemini/oauth_creds.json"
const OAUTH2_PATH = "~/.bun/install/global/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"

const LOAD_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
const QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
const PROJECTS_URL = "https://cloudresourcemanager.googleapis.com/v1/projects"
const TOKEN_URL = "https://oauth2.googleapis.com/token"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function makeJwt(payload) {
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" }), "utf8").toString("base64url")
  const body = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url")
  return `${header}.${body}.sig`
}

describe("gemini plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when auth type is api-key", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(SETTINGS_PATH, JSON.stringify({ authType: "api-key" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("api-key")
  })

  it("throws when auth type is unsupported", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(SETTINGS_PATH, JSON.stringify({ authType: "unknown-mode" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("unsupported auth type")
  })

  it("throws when creds are missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("refreshes token, parses plan, and returns pro + flash usage", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)

    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "old-token",
        refresh_token: "refresh-token",
        id_token: makeJwt({ email: "me@example.com" }),
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.fs.writeText(
      OAUTH2_PATH,
      "const OAUTH_CLIENT_ID='client-id'; const OAUTH_CLIENT_SECRET='client-secret';"
    )

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === TOKEN_URL) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      if (url === LOAD_CODE_ASSIST_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({ tier: "standard-tier", cloudaicompanionProject: "gen-lang-client-123" }),
        }
      }
      if (url === QUOTA_URL) {
        expect(opts.headers.Authorization).toBe("Bearer new-token")
        expect(opts.bodyText).toContain("gen-lang-client-123")
        return {
          status: 200,
          bodyText: JSON.stringify({
            quotaBuckets: [
              { modelId: "gemini-2.5-pro", remainingFraction: 0.2, resetTime: "2099-01-01T00:00:00Z" },
              { modelId: "gemini-2.5-pro", remainingFraction: 0.4, resetTime: "2099-01-01T00:00:00Z" },
              { modelId: "gemini-2.0-flash", remainingFraction: 0.6, resetTime: "2099-01-02T00:00:00Z" },
            ],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Paid")

    const pro = result.lines.find((line) => line.label === "Pro")
    const flash = result.lines.find((line) => line.label === "Flash")
    const account = result.lines.find((line) => line.label === "Account")
    expect(pro && pro.used).toBe(80)
    expect(flash && flash.used).toBe(40)
    expect(account && account.value).toBe("me@example.com")

    const persisted = JSON.parse(ctx.host.fs.readText(CREDS_PATH))
    expect(persisted.access_token).toBe("new-token")
  })

  it("uses project fallback and maps workspace tier", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)

    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        id_token: makeJwt({ email: "corp@example.com", hd: "example.com" }),
        expiry_date: nowMs + 3600_000,
      })
    )

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) {
        return { status: 200, bodyText: JSON.stringify({ tier: "free-tier" }) }
      }
      if (url === PROJECTS_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({ projects: [{ projectId: "other-project" }, { projectId: "gen-lang-client-456" }] }),
        }
      }
      if (url === QUOTA_URL) {
        expect(opts.bodyText).toContain("gen-lang-client-456")
        return {
          status: 200,
          bodyText: JSON.stringify({
            buckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.75, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Workspace")
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("retries loadCodeAssist on 401 and continues", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)

    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "stale-token",
        refresh_token: "refresh-token",
        id_token: makeJwt({ email: "me@example.com" }),
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.fs.writeText(
      OAUTH2_PATH,
      "const OAUTH_CLIENT_ID='client-id'; const OAUTH_CLIENT_SECRET='client-secret';"
    )

    let loadCodeAssistCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) {
        loadCodeAssistCalls += 1
        if (loadCodeAssistCalls === 1) return { status: 401, bodyText: "" }
        return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      }
      if (url === TOKEN_URL) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      if (url === QUOTA_URL) {
        expect(opts.headers.Authorization).toBe("Bearer new-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            quotaBuckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.2, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(loadCodeAssistCalls).toBe(2)
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("throws session expired when loadCodeAssist keeps returning 401", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)

    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        id_token: makeJwt({ email: "me@example.com" }),
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.fs.writeText(
      OAUTH2_PATH,
      "const OAUTH_CLIENT_ID='client-id'; const OAUTH_CLIENT_SECRET='client-secret';"
    )

    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 401, bodyText: "" }
      if (url === TOKEN_URL) {
        return { status: 200, bodyText: JSON.stringify({ access_token: "new-token", expires_in: 3600 }) }
      }
      return { status: 404, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("session expired")
  })

  it("throws when auth type is vertex-ai", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(SETTINGS_PATH, JSON.stringify({ authType: "vertex-ai" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("vertex-ai")
  })

  it("falls back when settings cannot be read", async () => {
    const ctx = makeCtx()
    const readText = vi.fn((path) => {
      if (path === SETTINGS_PATH) throw new Error("boom")
      return null
    })
    ctx.host.fs.exists = (path) => path === SETTINGS_PATH
    ctx.host.fs.readText = readText

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("treats creds without tokens as not logged in", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(CREDS_PATH, JSON.stringify({ user: "me" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("treats non-object creds payload as not logged in", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(CREDS_PATH, JSON.stringify("bad-shape"))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws not logged in when refresh is needed but cannot be performed", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        refresh_token: "refresh-token",
        expiry_date: nowMs - 1000,
      })
    )

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("continues with existing token when refresh token is missing", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "existing-token",
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-888" }] }) }
      if (url === QUOTA_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            buckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.6, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("continues with existing access token when oauth client creds are missing", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "existing-token",
        refresh_token: "refresh-token",
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.fs.writeText(OAUTH2_PATH, "not oauth creds")
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) {
        return { status: 200, bodyText: JSON.stringify({ tier: "legacy-tier" }) }
      }
      if (url === PROJECTS_URL) {
        return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-123" }] }) }
      }
      if (url === QUOTA_URL) {
        expect(opts.headers.Authorization).toBe("Bearer existing-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            buckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.3, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Legacy")
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("continues when refresh request throws and an access token already exists", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "existing-token",
        refresh_token: "refresh-token",
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.fs.writeText(
      OAUTH2_PATH,
      "const OAUTH_CLIENT_ID='client-id'; const OAUTH_CLIENT_SECRET='client-secret';"
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === TOKEN_URL) throw new Error("network")
      if (url === LOAD_CODE_ASSIST_URL) {
        return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      }
      if (url === PROJECTS_URL) {
        return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-456" }] }) }
      }
      if (url === QUOTA_URL) {
        expect(opts.headers.Authorization).toBe("Bearer existing-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            quotaBuckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.5, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Paid")
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("continues with existing token when refresh returns non-2xx", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "existing-token",
        refresh_token: "refresh-token",
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.fs.writeText(
      OAUTH2_PATH,
      "const OAUTH_CLIENT_ID='client-id'; const OAUTH_CLIENT_SECRET='client-secret';"
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === TOKEN_URL) return { status: 500, bodyText: "{}" }
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-777" }] }) }
      if (url === QUOTA_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            buckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.5, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("ignores non-string oauth2.js payload and continues", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "existing-token",
        refresh_token: "refresh-token",
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.fs.exists = (path) => path === CREDS_PATH || path === OAUTH2_PATH
    ctx.host.fs.readText = vi.fn((path) => {
      if (path === CREDS_PATH) {
        return JSON.stringify({
          access_token: "existing-token",
          refresh_token: "refresh-token",
          expiry_date: nowMs - 1000,
        })
      }
      if (path === OAUTH2_PATH) return null
      return null
    })
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-666" }] }) }
      if (url === QUOTA_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            buckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.4, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
  })

  it("skips proactive refresh when expiry_date is non-numeric", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: "not-a-number",
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-555" }] }) }
      if (url === QUOTA_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            buckets: [{ modelId: "gemini-2.5-pro", remainingFraction: 0.5, resetTime: "2099-01-01T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
    expect(
      ctx.host.http.request.mock.calls.some((call) => String(call[0]?.url) === TOKEN_URL)
    ).toBe(false)
  })

  it("throws session expired when proactive refresh is unauthorized", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs - 1000,
      })
    )
    ctx.host.fs.writeText(
      OAUTH2_PATH,
      "const OAUTH_CLIENT_ID='client-id'; const OAUTH_CLIENT_SECRET='client-secret';"
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === TOKEN_URL) return { status: 401, bodyText: JSON.stringify({ error: "unauthorized" }) }
      return { status: 500, bodyText: "{}" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Gemini session expired")
  })

  it("returns free plan and status badge when quota has no recognized buckets", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "free-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [] }) }
      if (url === QUOTA_URL) return { status: 200, bodyText: JSON.stringify({ buckets: [{ modelId: "other-model", remainingFraction: 0.2 }] }) }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("Free")
    const status = result.lines.find((line) => line.label === "Status")
    expect(status && status.text).toBe("No usage data")
  })

  it("throws session expired when loadCodeAssist returns auth and refresh cannot recover", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 401, bodyText: "" }
      return { status: 404, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("session expired")
  })

  it("throws when quota request is unauthorized and refresh cannot recover", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-789" }] }) }
      if (url === QUOTA_URL) return { status: 401, bodyText: "" }
      return { status: 404, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("session expired")
  })

  it("throws when quota request returns non-2xx", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-321" }] }) }
      if (url === QUOTA_URL) return { status: 500, bodyText: "" }
      return { status: 404, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("quota request failed")
  })

  it("throws when quota response JSON is invalid", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-111" }] }) }
      if (url === QUOTA_URL) return { status: 200, bodyText: "bad-json" }
      return { status: 404, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("quota response invalid")
  })

  it("reads project id from labels when loadCodeAssist does not provide one", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 500, bodyText: "{}" }
      if (url === PROJECTS_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({ projects: [{ projectId: "labeled-project", labels: { "generative-language": "1" } }] }),
        }
      }
      if (url === QUOTA_URL) {
        expect(opts.bodyText).toContain("labeled-project")
        return {
          status: 200,
          bodyText: JSON.stringify({
            quotaBuckets: [{ modelId: "gemini-2.5-flash", remainingFraction: 0.4, resetTime: "2099-01-02T00:00:00Z" }],
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Flash")).toBeTruthy()
  })

  it("uses snake_case quota fields and still renders lines", async () => {
    const ctx = makeCtx()
    const nowMs = 1_700_000_000_000
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    ctx.host.fs.writeText(
      CREDS_PATH,
      JSON.stringify({
        access_token: "token",
        refresh_token: "refresh-token",
        expiry_date: nowMs + 3600_000,
      })
    )
    ctx.host.http.request.mockImplementation((opts) => {
      const url = String(opts.url)
      if (url === LOAD_CODE_ASSIST_URL) return { status: 200, bodyText: JSON.stringify({ tier: "standard-tier" }) }
      if (url === PROJECTS_URL) return { status: 200, bodyText: JSON.stringify({ projects: [{ projectId: "gen-lang-client-909" }] }) }
      if (url === QUOTA_URL) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            data: {
              items: [
                { model_id: "gemini-2.5-pro", remainingFraction: 0.1, reset_time: "2099-01-01T00:00:00Z" },
                { modelId: "gemini-2.0-flash", remainingFraction: 0.8, resetTime: "2099-01-02T00:00:00Z" },
              ],
            },
          }),
        }
      }
      throw new Error("unexpected url: " + url)
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Pro")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Flash")).toBeTruthy()
  })
})
