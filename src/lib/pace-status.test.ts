import { describe, expect, it } from "vitest"

import { calculatePaceStatus } from "@/lib/pace-status"

const ONE_DAY_MS = 24 * 60 * 60 * 1000

function midPeriodNowAndReset() {
  const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
  const nowMs = Date.parse("2026-02-02T12:00:00.000Z")
  return { resetsAtMs, nowMs }
}

describe("pace-status", () => {
  it("returns null for non-finite inputs", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    expect(calculatePaceStatus(Number.NaN, 100, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, Number.POSITIVE_INFINITY, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, Number.NaN, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, resetsAtMs, Number.NaN, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, resetsAtMs, ONE_DAY_MS, Number.NaN)).toBeNull()
  })

  it("returns null for invalid limits or period duration", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    expect(calculatePaceStatus(10, 0, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, -5, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, resetsAtMs, 0, nowMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, resetsAtMs, -ONE_DAY_MS, nowMs)).toBeNull()
  })

  it("returns null when period has not started or is already reset", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodDurationMs = ONE_DAY_MS
    const periodStartMs = resetsAtMs - periodDurationMs
    expect(calculatePaceStatus(10, 100, resetsAtMs, periodDurationMs, periodStartMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, resetsAtMs, periodDurationMs, resetsAtMs)).toBeNull()
    expect(calculatePaceStatus(10, 100, resetsAtMs, periodDurationMs, resetsAtMs + 1)).toBeNull()
  })

  it("returns null when less than 5% of a short period has elapsed", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodDurationMs = ONE_DAY_MS
    const periodStartMs = resetsAtMs - periodDurationMs
    const beforeThresholdNowMs = periodStartMs + Math.floor(periodDurationMs * 0.049)
    expect(calculatePaceStatus(10, 100, resetsAtMs, periodDurationMs, beforeThresholdNowMs)).toBeNull()
  })

  it("uses 1% threshold for long periods (>24h)", () => {
    const THIRTY_DAYS_MS = 30 * ONE_DAY_MS
    const resetsAtMs = Date.parse("2026-03-05T00:00:00.000Z")
    const periodStartMs = resetsAtMs - THIRTY_DAYS_MS
    // 0.5% elapsed = too early even for long periods
    const tooEarlyMs = periodStartMs + Math.floor(THIRTY_DAYS_MS * 0.005)
    expect(calculatePaceStatus(10, 100, resetsAtMs, THIRTY_DAYS_MS, tooEarlyMs)).toBeNull()
    // 2% elapsed = enough for long periods (but would fail 5% threshold)
    const earlyButOkMs = periodStartMs + Math.floor(THIRTY_DAYS_MS * 0.02)
    const result = calculatePaceStatus(10, 100, resetsAtMs, THIRTY_DAYS_MS, earlyButOkMs)
    expect(result).not.toBeNull()
    expect(result!.status).toBe("behind") // 10 used in 2% → projected 500, way over 100
  })

  it("returns ahead for zero usage (skips 5% threshold)", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodDurationMs = ONE_DAY_MS
    const periodStartMs = resetsAtMs - periodDurationMs
    // 45 min in = 3.1% < 5%, but used === 0 should still return ahead
    const earlyNowMs = periodStartMs + 45 * 60 * 1000
    expect(calculatePaceStatus(0, 100, resetsAtMs, periodDurationMs, earlyNowMs)).toEqual({
      status: "ahead",
      projectedUsage: 0,
    })
  })

  it("returns behind for over-limit usage (skips 5% threshold)", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(120, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "behind", projectedUsage: 240 })
  })

  it("classifies ahead of pace", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(30, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "ahead", projectedUsage: 60 })
  })

  it("classifies on-track at the limit boundary", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(50, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "on-track", projectedUsage: 100 })
  })

  it("classifies behind", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(60, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "behind", projectedUsage: 120 })
  })
})
