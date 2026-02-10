import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

describe("cliproxyapi plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when config is missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not configured")
  })

  it("shows connected status with provider summary", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ baseUrl: "localhost:8317", apiKey: "secret" })
    )
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        files: [
          { provider: "codex", name: "codex-main.json", disabled: false, unavailable: false },
          { provider: "anthropic", name: "claude-main.json", disabled: false, unavailable: false },
          { provider: "codex", name: "codex-disabled.json", disabled: true, unavailable: false },
        ],
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines.find((line) => line.label === "Status")?.value).toBe("Connected")
    expect(result.lines.find((line) => line.label === "Accounts")?.value).toBe("3")
    expect(result.lines.find((line) => line.label === "Providers")?.value).toContain("claude: 1")
    expect(result.lines.find((line) => line.label === "Providers")?.value).toContain("codex: 1")
  })

  it("throws when auth-files request fails", async () => {
    const ctx = makeCtx()
    ctx.host.keychain.readGenericPassword.mockReturnValue(
      JSON.stringify({ baseUrl: "http://localhost:8317", apiKey: "secret" })
    )
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "{}" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Request failed")
  })
})
