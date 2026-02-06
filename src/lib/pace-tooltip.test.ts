import { describe, expect, it } from "vitest"

import { type PaceResult } from "@/lib/pace-status"
import {
  buildPaceDetailText,
  formatCompactDuration,
  getLimitHitEtaText,
  getPaceStatusText,
} from "@/lib/pace-tooltip"

const ONE_DAY_MS = 24 * 60 * 60 * 1000
const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
const nowMs = Date.parse("2026-02-02T12:00:00.000Z")

describe("pace-tooltip", () => {
  it("maps pace status labels", () => {
    expect(getPaceStatusText("ahead")).toBe("Ahead of pace")
    expect(getPaceStatusText("on-track")).toBe("On track")
    expect(getPaceStatusText("behind")).toBe("Using fast")
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

  it("computes ETA text when 100% is reached before reset", () => {
    const eta = getLimitHitEtaText({
      used: 60,
      limit: 100,
      resetsAtMs,
      periodDurationMs: ONE_DAY_MS,
      nowMs,
    })
    expect(eta).toBe("hits 100% in 8h 0m")
  })

  it("returns fallback now text when already at or above limit", () => {
    const eta = getLimitHitEtaText({
      used: 120,
      limit: 100,
      resetsAtMs,
      periodDurationMs: ONE_DAY_MS,
      nowMs,
    })
    expect(eta).toBe("at/over 100% now")
  })

  it("returns null when ETA cannot be computed", () => {
    expect(
      getLimitHitEtaText({
        used: 0,
        limit: 100,
        resetsAtMs,
        periodDurationMs: ONE_DAY_MS,
        nowMs,
      })
    ).toBeNull()

    expect(
      getLimitHitEtaText({
        used: 90,
        limit: 100,
        resetsAtMs,
        periodDurationMs: ONE_DAY_MS,
        nowMs: Date.parse("2026-02-02T23:59:00.000Z"),
      })
    ).toBeNull()
  })

  it("builds projected detail text for <=100% projections", () => {
    const paceResult: PaceResult = { status: "on-track", projectedUsage: 90 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 45,
      limit: 100,
      resetsAtMs,
      periodDurationMs: ONE_DAY_MS,
      nowMs,
    })
    expect(detail).toBe("projected 90% by reset")
  })

  it("prefers ETA text when projected usage exceeds 100%", () => {
    const paceResult: PaceResult = { status: "behind", projectedUsage: 120 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 60,
      limit: 100,
      resetsAtMs,
      periodDurationMs: ONE_DAY_MS,
      nowMs,
    })
    expect(detail).toBe("hits 100% in 8h 0m")
  })

  it("falls back to projected text when projected >100 but ETA is unavailable", () => {
    const paceResult: PaceResult = { status: "behind", projectedUsage: 120 }
    const detail = buildPaceDetailText({
      paceResult,
      used: 0,
      limit: 100,
      resetsAtMs,
      periodDurationMs: ONE_DAY_MS,
      nowMs,
    })
    expect(detail).toBe("projected 120% by reset")
  })

  it("returns null detail when pace result is unavailable", () => {
    const detail = buildPaceDetailText({
      paceResult: null,
      used: 30,
      limit: 100,
      resetsAtMs,
      periodDurationMs: ONE_DAY_MS,
      nowMs,
    })
    expect(detail).toBeNull()
  })
})
