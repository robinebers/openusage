import { describe, expect, it } from "vitest"

import { type PaceResult } from "@/lib/pace-status"
import {
  buildPaceDetailText,
  formatCompactDuration,
  getPaceStatusText,
} from "@/lib/pace-tooltip"

const ONE_DAY_MS = 24 * 60 * 60 * 1000
const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
const nowMs = Date.parse("2026-02-02T12:00:00.000Z")

describe("pace-tooltip", () => {
  it("maps pace status labels", () => {
    expect(getPaceStatusText("ahead")).toBe("Plenty of room")
    expect(getPaceStatusText("on-track")).toBe("Right on target")
    expect(getPaceStatusText("behind")).toBe("Will run out")
  })

  it("formats compact durations", () => {
    expect(formatCompactDuration(30_000)).toBe("<1m")
    expect(formatCompactDuration(5 * 60_000)).toBe("5m")
    expect(formatCompactDuration((8 * 60 + 5) * 60_000)).toBe("8h 5m")
    expect(formatCompactDuration((2 * 24 + 3) * 60 * 60_000)).toBe("2d 3h")
  })

  it("returns null for invalid compact duration", () => {
    expect(formatCompactDuration(Number.NaN)).toBeNull()
    expect(formatCompactDuration(0)).toBeNull()
  })

  it("shows 'Limit in' ETA for behind pace", () => {
    // projectedUsage=120, rate=120/ONE_DAY_MS, ETA=(100-60)/rate = 8h
    const paceResult: PaceResult = { status: "behind", projectedUsage: 120 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 60,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "used",
    })
    expect(detail).toBe("Limit in 8h 0m")
  })

  it("shows projected % used at reset for on-track (displayMode=used)", () => {
    const paceResult: PaceResult = { status: "on-track", projectedUsage: 90 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 45,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "used",
    })
    expect(detail).toBe("90% used at reset")
  })

  it("shows projected % left at reset for on-track (displayMode=left)", () => {
    const paceResult: PaceResult = { status: "on-track", projectedUsage: 90 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 45,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "left",
    })
    expect(detail).toBe("10% left at reset")
  })

  it("shows projected % for ahead (displayMode=used)", () => {
    const paceResult: PaceResult = { status: "ahead", projectedUsage: 60 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 30,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "used",
    })
    expect(detail).toBe("60% used at reset")
  })

  it("shows projected % for ahead (displayMode=left)", () => {
    const paceResult: PaceResult = { status: "ahead", projectedUsage: 60 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 30,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "left",
    })
    expect(detail).toBe("40% left at reset")
  })

  it("clamps projected percent to 100% when behind without ETA", () => {
    // projectedUsage=120 > limit, but used=0 so rate=0 → no ETA → falls through to clamped %
    const paceResult: PaceResult = { status: "behind", projectedUsage: 120 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 0,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "used",
    })
    expect(detail).toBe("100% used at reset")
  })

  it("clamps projected percent in left mode when behind without ETA", () => {
    const paceResult: PaceResult = { status: "behind", projectedUsage: 120 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 0,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "left",
    })
    expect(detail).toBe("0% left at reset")
  })

  it("returns null when pace result is unavailable", () => {
    const detail = buildPaceDetailText({
      paceResult: null,
      used: 30,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs,
      displayMode: "used",
    })
    expect(detail).toBeNull()
  })

  it("falls through to projected % when ETA exceeds remaining time", () => {
    // 90% used at 23:59, only 1 min left — ETA would be ~1.1min but limit won't be hit before reset
    const lateNowMs = Date.parse("2026-02-02T23:59:00.000Z")
    const paceResult: PaceResult = { status: "behind", projectedUsage: 110 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 90,
      limit: 100,
      periodDurationMs: ONE_DAY_MS,
      resetsAtMs,
      nowMs: lateNowMs,
      displayMode: "used",
    })
    expect(detail).toBe("100% used at reset")
  })
})
