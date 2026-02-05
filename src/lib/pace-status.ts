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
  // Validate inputs
  if (
    !Number.isFinite(used) ||
    !Number.isFinite(limit) ||
    !Number.isFinite(resetsAtMs) ||
    !Number.isFinite(periodDurationMs) ||
    !Number.isFinite(nowMs)
  ) {
    return null
  }

  if (limit <= 0 || periodDurationMs <= 0) {
    return null
  }

  // Calculate period start and elapsed time
  const periodStartMs = resetsAtMs - periodDurationMs
  const elapsedMs = nowMs - periodStartMs

  // Skip if period hasn't started or we're past the reset
  if (elapsedMs <= 0 || nowMs >= resetsAtMs) {
    return null
  }

  // Skip if less than 5% of period has elapsed (too early to predict accurately)
  const elapsedFraction = elapsedMs / periodDurationMs
  if (elapsedFraction < 0.05) {
    return null
  }

  // Calculate projected usage at end of period
  // projectedUsage = (used / elapsedTime) * periodDuration
  const usageRate = used / elapsedMs
  const projectedUsage = usageRate * periodDurationMs

  // Determine status based on projected usage vs limit
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
 * Get the CSS color class for a pace status.
 */
export function getPaceStatusColor(status: PaceStatus): string {
  switch (status) {
    case "ahead":
      return "text-green-500"
    case "on-track":
      return "text-yellow-500"
    case "behind":
      return "text-red-500"
  }
}
