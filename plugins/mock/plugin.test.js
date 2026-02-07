import { beforeEach, describe, expect, it, vi } from "vitest"
import { makePluginTestContext } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

const createCtx = (overrides) => makePluginTestContext(overrides, vi)

describe("mock plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    if (vi.resetModules) vi.resetModules()
  })

  it("returns stress-test lines", async () => {
    const plugin = await loadPlugin()
    const result = plugin.probe(createCtx())
    expect(result.plan).toBe("stress-test")
    expect(result.lines.length).toBeGreaterThanOrEqual(16)
  })

  it("includes progress lines with all edge cases", async () => {
    const plugin = await loadPlugin()
    const result = plugin.probe(createCtx())
    const progressLabels = result.lines
      .filter((l) => l.type === "progress")
      .map((l) => l.label)
    expect(progressLabels).toContain("Ahead pace")
    expect(progressLabels).toContain("Empty bar")
    expect(progressLabels).toContain("Over limit!")
    expect(progressLabels).toContain("Huge numbers")
    expect(progressLabels).toContain("Expired reset")
  })

  it("includes text and badge lines", async () => {
    const plugin = await loadPlugin()
    const result = plugin.probe(createCtx())
    expect(result.lines.find((l) => l.type === "text" && l.label === "Status")).toBeTruthy()
    expect(result.lines.find((l) => l.type === "badge" && l.label === "Tier")).toBeTruthy()
  })

  it("sets resetsAt and periodDurationMs on pace lines", async () => {
    const plugin = await loadPlugin()
    const result = plugin.probe(createCtx())
    const ahead = result.lines.find((l) => l.label === "Ahead pace")
    expect(ahead.resetsAt).toBeTruthy()
    expect(ahead.periodDurationMs).toBeGreaterThan(0)
  })
})
