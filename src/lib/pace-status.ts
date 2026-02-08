export type PaceStatus = "ahead" | "on-track" | "behind"

export type PaceResult = {
  status: PaceStatus
  /** Projected usage at end of period (same unit as used/limit) */
  projectedUsage: number
}

/**
 * Calculate pace status based on current usage rate vs. period duration.
 *
 * @param used - Current usage amount
 * @param limit - Maximum/limit amount
 * @param resetsAtMs - Timestamp (ms) when the period resets
 * @param periodDurationMs - Total duration of the period (ms)
 * @param nowMs - Current timestamp (ms)
 * @returns PaceResult or null if calculation not possible
 */
export function calculatePaceStatus(
  used: number,
  limit: number,
  resetsAtMs: number,
  periodDurationMs: number,
  nowMs: number
): PaceResult | null {
  if (
    !Number.isFinite(used) ||
    !Number.isFinite(limit) ||
    !Number.isFinite(resetsAtMs) ||
    !Number.isFinite(periodDurationMs) ||
    !Number.isFinite(nowMs)
  ) {
    return null
  }

  if (limit <= 0 || periodDurationMs <= 0) return null

  const periodStartMs = resetsAtMs - periodDurationMs
  const elapsedMs = nowMs - periodStartMs
  if (elapsedMs <= 0 || nowMs >= resetsAtMs) return null

  // No usage = definitionally ahead of pace (skip 5% threshold)
  if (used === 0) return { status: "ahead", projectedUsage: 0 }

  const usageRate = used / elapsedMs
  const projectedUsage = usageRate * periodDurationMs

  // Already at/over limit = definitionally behind (skip 5% threshold)
  if (used >= limit) return { status: "behind", projectedUsage }

  // Too early to predict accurately — use adaptive threshold:
  // Short periods (<=24h): 5% minimum elapsed
  // Long periods (>24h): 1% minimum elapsed (to avoid multi-day blindspot)
  const elapsedFraction = elapsedMs / periodDurationMs
  const ONE_DAY_MS = 24 * 60 * 60 * 1000
  const minElapsedFraction = periodDurationMs > ONE_DAY_MS ? 0.01 : 0.05
  if (elapsedFraction < minElapsedFraction) return null

  // Normal classification:
  // - projected below limit => reserve remains (green)
  // - projected around limit => neutral (amber)
  // - projected above limit => risk (red)
  const tolerance = limit * 0.005 // 0.5% band to avoid jitter at boundary
  let status: PaceStatus
  if (projectedUsage < limit - tolerance) {
    status = "ahead"
  } else if (projectedUsage <= limit + tolerance) {
    status = "on-track"
  } else {
    status = "behind"
  }

  return { status, projectedUsage }
}
