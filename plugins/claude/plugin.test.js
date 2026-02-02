import { beforeEach, describe, expect, it, vi } from "vitest"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const makeCtx = () => {
  const files = new Map()
  return {
    host: {
      fs: {
        exists: (path) => files.has(path),
        readText: (path) => files.get(path),
      },
      keychain: {
        readGenericPassword: vi.fn(),
      },
      http: {
        request: vi.fn(),
      },
    },
  }
}

describe("claude plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("returns login required when no credentials", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].label).toBe("Error")
  })

  it("returns login required when credentials are unreadable", async () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => true
    ctx.host.fs.readText = () => "{bad json"
    ctx.host.keychain.readGenericPassword.mockReturnValue("{bad}")
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("Login required")
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
    expect(result.lines.find((line) => line.label === "Plan")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Session (5h)")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Weekly (7d)")).toBeTruthy()
  })

  it("returns token expired on 401", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({ status: 401, bodyText: "" })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("Token expired")
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
    expect(result.lines.find((line) => line.label === "Sonnet (7d)")).toBeTruthy()
    expect(result.lines.find((line) => line.label === "Extra usage")).toBeTruthy()
  })

  it("handles http errors and parse failures", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValueOnce({ status: 500, bodyText: "" })
    const plugin = await loadPlugin()
    const httpError = plugin.probe(ctx)
    expect(httpError.lines[0].text).toMatch("HTTP")

    ctx.host.http.request.mockReturnValueOnce({ status: 200, bodyText: "not-json" })
    const parseError = plugin.probe(ctx)
    expect(parseError.lines[0].text).toBe("cannot parse usage response")
  })

  it("handles request throws", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("boom")
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].text).toBe("usage request failed")
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

  it("formats reset windows under an hour", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    const now = new Date("2026-02-02T00:00:00.000Z").getTime()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        five_hour: { utilization: 10, resets_at: new Date(now + 30_000).toISOString() },
        seven_day: { utilization: 20, resets_at: new Date(now + 5 * 60_000).toISOString() },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const resetLines = result.lines.filter((line) => line.label === "Resets in")
    expect(resetLines.some((line) => line.value === "<1m")).toBe(true)
    expect(resetLines.some((line) => line.value === "5m")).toBe(true)
    nowSpy.mockRestore()
  })

  it("handles invalid reset timestamps", async () => {
    const ctx = makeCtx()
    ctx.host.fs.readText = () => JSON.stringify({ claudeAiOauth: { accessToken: "token" } })
    ctx.host.fs.exists = () => true
    ctx.host.http.request.mockReturnValue({
      status: 200,
      bodyText: JSON.stringify({
        seven_day_opus: { utilization: 33, resets_at: "not-a-date" },
      }),
    })
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Opus (7d)")).toBeTruthy()
  })
})
