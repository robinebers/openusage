import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const SETTINGS_HTML = `
  <main>
    <h1>Cloud Usage <span>Pro</span></h1>
    <section>
      <h2>Session usage</h2>
      <span class="text-sm">0.6% used</span>
      <time data-time="2026-05-16T14:55:00Z">Resets in 55 minutes</time>
    </section>
    <section>
      <h2>Weekly usage</h2>
      <span class="text-sm">17.9% used</span>
      <time data-time="2026-05-17T13:00:00Z">Resets in 1 day</time>
    </section>
  </main>
`

const RELATIVE_HTML = `
  <main>
    <h1>Cloud Usage <span>Max</span></h1>
    <section>
      <h2>Session usage</h2>
      <span>2.5% used</span>
      <p>Resets in 30 minutes</p>
    </section>
    <section>
      <h2>Weekly usage</h2>
      <span>10% used</span>
      <p>Resets in 2 days</p>
    </section>
  </main>
`

const mockEnv = (ctx, values) => {
  ctx.host.env.get.mockImplementation((name) => values[name] || null)
}

const mockSettings = (ctx, html = SETTINGS_HTML) => {
  ctx.host.http.request.mockImplementation((opts) => {
    expect(opts.url).toBe("https://ollama.com/settings")
    expect(opts.headers.Cookie).toBe("__Secure-session=session-value")
    return { status: 200, bodyText: html }
  })
}

describe("ollama plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when no auth is available", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()

    expect(() => plugin.probe(ctx)).toThrow("Ollama auth missing")
  })

  it("reads settings usage from OLLAMA_SESSION_COOKIE", async () => {
    const ctx = makeCtx()
    mockEnv(ctx, { OLLAMA_SESSION_COOKIE: "session-value" })
    mockSettings(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    const session = result.lines.find((line) => line.label === "Session")
    const weekly = result.lines.find((line) => line.label === "Weekly")
    expect(session.used).toBe(0.6)
    expect(session.limit).toBe(100)
    expect(session.resetsAt).toBe("2026-05-16T14:55:00Z")
    expect(weekly.used).toBe(17.9)
    expect(weekly.resetsAt).toBe("2026-05-17T13:00:00Z")
  })

  it("accepts a full cookie header from OLLAMA_COOKIE", async () => {
    const ctx = makeCtx()
    mockEnv(ctx, { OLLAMA_COOKIE: "aid=abc; __Secure-session=session-value; other=1" })
    mockSettings(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Session").used).toBe(0.6)
  })

  it("falls back to relative reset text", async () => {
    const ctx = makeCtx()
    ctx.nowIso = "2026-05-16T13:00:00.000Z"
    mockEnv(ctx, { OLLAMA_SESSION_COOKIE: "session-value" })
    mockSettings(ctx, RELATIVE_HTML)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const session = result.lines.find((line) => line.label === "Session")
    const weekly = result.lines.find((line) => line.label === "Weekly")

    expect(result.plan).toBe("Max")
    expect(session.resetsAt).toBe("2026-05-16T13:30:00.000Z")
    expect(weekly.resetsAt).toBe("2026-05-18T13:00:00.000Z")
  })

  it("uses settings scrape before future API usage when cookie exists", async () => {
    const ctx = makeCtx()
    mockEnv(ctx, { OLLAMA_API_KEY: "api-key", OLLAMA_SESSION_COOKIE: "session-value" })
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url.includes("/api/account/usage")) {
        throw new Error("API should not be fetched when settings auth exists")
      }
      return { status: 200, bodyText: SETTINGS_HTML }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(result.lines.find((line) => line.label === "Session").used).toBe(0.6)
    expect(result.lines.find((line) => line.label === "Source").value).toBe("Settings page")
  })

  it("falls back to future API usage when no cookie exists", async () => {
    const ctx = makeCtx()
    mockEnv(ctx, { OLLAMA_API_KEY: "api-key" })
    ctx.host.http.request.mockImplementation((opts) => {
      expect(opts.url).toBe("https://ollama.com/api/account/usage")
      return {
        status: 200,
        bodyText: JSON.stringify({
          plan: "pro",
          session: { used_percent: 3, resets_at: "2026-05-16T15:00:00Z" },
          weekly: { used_percent: 12, resets_at: "2026-05-18T00:00:00Z" },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    expect(result.lines.find((line) => line.label === "Session").used).toBe(3)
    expect(result.lines.find((line) => line.label === "Source").value).toBe("Ollama API")
  })

  it("uses Firefox cookie when env and keychain are missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite", "db")
    ctx.host.sqlite.query.mockReturnValue(JSON.stringify([{ value: "session-value" }]))
    mockSettings(ctx)

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Session").used).toBe(0.6)
    expect(ctx.host.sqlite.query).toHaveBeenCalledWith(
      "~/Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite",
      expect.stringContaining("__Secure-session")
    )
  })

  it("throws session expired on redirect", async () => {
    const ctx = makeCtx()
    mockEnv(ctx, { OLLAMA_SESSION_COOKIE: "session-value" })
    ctx.host.http.request.mockReturnValue({ status: 302, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Ollama session expired")
  })
})
