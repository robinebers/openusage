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
    vi.useRealTimers()
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
    expect(progressLabels).toContain("Time marker empty-side demo")
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

  it("configures an empty-side time marker demo line", async () => {
    vi.useFakeTimers()
    const baseNow = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(baseNow)
    const plugin = await loadPlugin()
    const result = plugin.probe(createCtx())
    const demo = result.lines.find((l) => l.label === "Time marker empty-side demo")
    expect(demo).toBeTruthy()
    expect(demo?.used).toBe(20)
    expect(demo?.limit).toBe(100)
    expect(demo?.periodDurationMs).toBe(24 * 60 * 60 * 1000)
    expect(Date.parse(demo.resetsAt) - Date.now()).toBe(12 * 60 * 60 * 1000)

    // In default "used" mode this places the time marker (50%) to the right of fill (20%).
    const elapsedPercent = ((demo.periodDurationMs - (Date.parse(demo.resetsAt) - Date.now())) / demo.periodDurationMs) * 100
    expect(elapsedPercent).toBeGreaterThan(demo.used)
  })

  it("includes reset ranges for minute/hour/day/week outputs", async () => {
    vi.useFakeTimers()
    const baseNow = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(baseNow)
    const plugin = await loadPlugin()
    const result = plugin.probe(createCtx())
    const nowMs = Date.now()

    const resetInMinutes = result.lines.find((l) => l.label === "Reset in minutes")
    const resetInHours = result.lines.find((l) => l.label === "Reset in hours")
    const resetInDays = result.lines.find((l) => l.label === "Reset in days")
    const resetInWeek = result.lines.find((l) => l.label === "Reset in week+")

    expect(resetInMinutes?.resetsAt).toBeTruthy()
    expect(resetInHours?.resetsAt).toBeTruthy()
    expect(resetInDays?.resetsAt).toBeTruthy()
    expect(resetInWeek?.resetsAt).toBeTruthy()

    const minutesDeltaMs = Date.parse(resetInMinutes.resetsAt) - nowMs
    const hoursDeltaMs = Date.parse(resetInHours.resetsAt) - nowMs
    const daysDeltaMs = Date.parse(resetInDays.resetsAt) - nowMs
    const weekDeltaMs = Date.parse(resetInWeek.resetsAt) - nowMs

    expect(minutesDeltaMs).toBe(10 * 60 * 1000)
    expect(hoursDeltaMs).toBe(6 * 60 * 60 * 1000)
    expect(daysDeltaMs).toBe((2 * 24 + 3) * 60 * 60 * 1000)
    expect(weekDeltaMs).toBe(8 * 24 * 60 * 60 * 1000)
  })
})
