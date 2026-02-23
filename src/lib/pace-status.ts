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

  // Too early to predict accurately (< 5% of period elapsed)
  const elapsedFraction = elapsedMs / periodDurationMs
  if (elapsedFraction < 0.05) return null

  // Normal classification
  let status: PaceStatus
  if (projectedUsage <= limit * 0.8) {
    status = "ahead"
  } else if (projectedUsage <= limit) {
    status = "on-track"
  } else {
    status = "behind"
  }

  return { status, projectedUsage }
}

/**
 * How much usage exceeds the ideal linear pace (same unit as used/limit).
 * Returns positive deficit or null when ahead/on-pace/incalculable.
 */
export function calculateDeficit(
  used: number,
  limit: number,
  resetsAtMs: number,
  periodDurationMs: number,
  nowMs: number
): number | null {
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

  const elapsedFraction = elapsedMs / periodDurationMs
  if (elapsedFraction < 0.05 && used < limit) return null

  const expectedUsage = elapsedFraction * limit
  const deficit = used - expectedUsage
  return deficit > 0 ? deficit : null
}
