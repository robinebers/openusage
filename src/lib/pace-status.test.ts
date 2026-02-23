import { describe, expect, it } from "vitest"

import { calculateDeficit, calculatePaceStatus } from "@/lib/pace-status"

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

  it("returns null when less than 5% of the period has elapsed", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodDurationMs = ONE_DAY_MS
    const periodStartMs = resetsAtMs - periodDurationMs
    const beforeThresholdNowMs = periodStartMs + Math.floor(periodDurationMs * 0.049)
    expect(calculatePaceStatus(10, 100, resetsAtMs, periodDurationMs, beforeThresholdNowMs)).toBeNull()
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

  it("classifies on-track", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(45, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "on-track", projectedUsage: 90 })
  })

  it("classifies behind", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(60, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "behind", projectedUsage: 120 })
  })

  it("keeps 80% projected usage in ahead status", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(40, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "ahead", projectedUsage: 80 })
  })

  it("keeps 100% projected usage in on-track status", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    const result = calculatePaceStatus(50, 100, resetsAtMs, ONE_DAY_MS, nowMs)
    expect(result).toEqual({ status: "on-track", projectedUsage: 100 })
  })
})

describe("calculateDeficit", () => {
  it("returns null for non-finite inputs", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    expect(calculateDeficit(Number.NaN, 100, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculateDeficit(10, Number.POSITIVE_INFINITY, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculateDeficit(10, 100, Number.NaN, ONE_DAY_MS, nowMs)).toBeNull()
  })

  it("returns null for invalid limits or period duration", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    expect(calculateDeficit(10, 0, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    expect(calculateDeficit(10, 100, resetsAtMs, 0, nowMs)).toBeNull()
  })

  it("returns null when period has not started or is already reset", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodStartMs = resetsAtMs - ONE_DAY_MS
    expect(calculateDeficit(60, 100, resetsAtMs, ONE_DAY_MS, periodStartMs)).toBeNull()
    expect(calculateDeficit(60, 100, resetsAtMs, ONE_DAY_MS, resetsAtMs)).toBeNull()
  })

  it("returns null when less than 5% of the period has elapsed", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodStartMs = resetsAtMs - ONE_DAY_MS
    const earlyMs = periodStartMs + Math.floor(ONE_DAY_MS * 0.04)
    expect(calculateDeficit(60, 100, resetsAtMs, ONE_DAY_MS, earlyMs)).toBeNull()
  })

  it("returns deficit for over-limit usage even before 5% elapsed", () => {
    const resetsAtMs = Date.parse("2026-02-03T00:00:00.000Z")
    const periodStartMs = resetsAtMs - ONE_DAY_MS
    const earlyMs = periodStartMs + Math.floor(ONE_DAY_MS * 0.04)
    const deficit = calculateDeficit(120, 100, resetsAtMs, ONE_DAY_MS, earlyMs)
    expect(deficit).toBeCloseTo(116, 6)
  })

  it("returns deficit when usage exceeds expected pace", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    // 50% elapsed, 60% used → deficit = 60 - 50 = 10
    expect(calculateDeficit(60, 100, resetsAtMs, ONE_DAY_MS, nowMs)).toBe(10)
  })

  it("returns null when usage is at or below expected pace", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    // 50% elapsed, 50% used → no deficit
    expect(calculateDeficit(50, 100, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
    // 50% elapsed, 30% used → ahead
    expect(calculateDeficit(30, 100, resetsAtMs, ONE_DAY_MS, nowMs)).toBeNull()
  })

  it("returns deficit when over limit", () => {
    const { resetsAtMs, nowMs } = midPeriodNowAndReset()
    // 50% elapsed, 120% used → deficit = 120 - 50 = 70
    expect(calculateDeficit(120, 100, resetsAtMs, ONE_DAY_MS, nowMs)).toBe(70)
  })
})
