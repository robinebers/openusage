import { describe, expect, it } from "vitest"

import { calculatePaceStatus, getPaceStatusColor } from "@/lib/pace-status"

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

  it("maps pace status to color classes", () => {
    expect(getPaceStatusColor("ahead")).toBe("text-green-500")
    expect(getPaceStatusColor("on-track")).toBe("text-yellow-500")
    expect(getPaceStatusColor("behind")).toBe("text-red-500")
  })
})
