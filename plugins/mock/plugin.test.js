import { beforeEach, describe, expect, it, vi } from "vitest"
import { makePluginTestContext } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const createCtx = (overrides) => makePluginTestContext(overrides, vi)

const setConfig = (ctx, value) => {
  ctx.host.fs.writeText(ctx.app.pluginDataDir + "/config.json", JSON.stringify(value))
}

describe("mock plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    if (vi.resetModules) vi.resetModules()
  })

  it("initializes config and returns ok case", async () => {
    const ctx = createCtx()
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Percent")).toBeTruthy()
  })

  it("auto-migrates legacy ok config", async () => {
    const plugin = await loadPlugin()
    const ctx = createCtx()
    setConfig(ctx, { mode: "ok" })
    const result = plugin.probe(ctx)
    expect(result.plan).toBe("chaos")
    expect(result.lines.find((line) => line.label === "Case")).toBeTruthy()
  })

  it("renders ok mode when pinned", async () => {
    const plugin = await loadPlugin()
    const ctx = createCtx()
    setConfig(ctx, { pinned: true, mode: "ok" })
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Percent")).toBeTruthy()
  })

  it("stringifies non-string modes for warnings", async () => {
    const plugin = await loadPlugin()
    const ctx = createCtx()
    setConfig(ctx, { pinned: true, mode: { kind: "weird" } })
    const result = plugin.probe(ctx)
    const warning = result.lines.find((line) => line.label === "Warning")
    expect(warning?.text).toContain("\"kind\":\"weird\"")
  })

  it("falls back to default when config json is invalid", async () => {
    const plugin = await loadPlugin()
    const ctx = createCtx()
    ctx.host.fs.writeText(ctx.app.pluginDataDir + "/config.json", "{bad")
    const result = plugin.probe(ctx)
    expect(result.plan).toBeTruthy()
  })

  it("handles several pinned modes", async () => {
    const plugin = await loadPlugin()
    const ctx = createCtx()

    setConfig(ctx, { pinned: true, mode: "progress_max_na" })
    expect(plugin.probe(ctx).lines.find((line) => line.label === "Case")).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "progress_value_string" })
    expect(plugin.probe(ctx).lines.find((line) => line.label === "Case")).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "progress_value_nan" })
    expect(plugin.probe(ctx).lines.find((line) => line.label === "Case")).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "badge_text_number" })
    expect(plugin.probe(ctx).lines.find((line) => line.label === "Case")).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "lines_not_array" })
    expect(plugin.probe(ctx).lines).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "line_not_object" })
    expect(plugin.probe(ctx).lines).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "non_object" })
    expect(plugin.probe(ctx)).toBe("not an object")

    setConfig(ctx, { pinned: true, mode: "missing_lines" })
    expect(plugin.probe(ctx).lines).toBeUndefined()

    setConfig(ctx, { pinned: true, mode: "unknown_line_type" })
    expect(plugin.probe(ctx).lines.find((line) => line.type === "nope")).toBeTruthy()

    setConfig(ctx, { pinned: true, mode: "unknown_mode" })
    expect(plugin.probe(ctx).lines.find((line) => line.label === "Warning")).toBeTruthy()
  })

  it("throws or rejects for failure modes", async () => {
    const plugin = await loadPlugin()
    const ctx = createCtx()

    setConfig(ctx, { pinned: true, mode: "auth_required_cli" })
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")

    setConfig(ctx, { pinned: true, mode: "token_expired_cli" })
    await expect(plugin.probe(ctx)).rejects.toMatch("Token expired")

    setConfig(ctx, { pinned: true, mode: "unresolved_promise" })
    const unresolved = plugin.probe(ctx)
    expect(unresolved).toBeInstanceOf(Promise)

    setConfig(ctx, { pinned: true, mode: "http_throw" })
    ctx.host.http.request.mockImplementationOnce(() => {
      throw new Error("boom")
    })
    expect(() => plugin.probe(ctx)).toThrow()

    setConfig(ctx, { pinned: true, mode: "sqlite_throw" })
    ctx.host.sqlite.query.mockImplementationOnce(() => {
      throw new Error("boom")
    })
    expect(() => plugin.probe(ctx)).toThrow()

    setConfig(ctx, { pinned: true, mode: "fs_throw" })
    const originalReadText = ctx.host.fs.readText
    ctx.host.fs.readText = (path) => {
      if (String(path).includes("definitely/not")) {
        throw new Error("boom")
      }
      return originalReadText(path)
    }
    expect(() => plugin.probe(ctx)).toThrow()
  })
})
