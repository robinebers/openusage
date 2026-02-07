import type { PaceResult, PaceStatus } from "@/lib/pace-status"
import type { DisplayMode } from "@/lib/settings"

/** Sentinel value returned by buildPaceDetailText when usage >= limit */
export const LIMIT_REACHED = "Limit reached"

export function getPaceStatusText(status: PaceStatus): string {
  return status === "ahead" ? "You're good" : status === "on-track" ? "On track" : "Using fast"
}

export function formatCompactDuration(deltaMs: number): string | null {
  if (!Number.isFinite(deltaMs) || deltaMs <= 0) return null
  const totalSeconds = Math.floor(deltaMs / 1000)
  const totalMinutes = Math.floor(totalSeconds / 60)
  const totalHours = Math.floor(totalMinutes / 60)
  const days = Math.floor(totalHours / 24)
  const hours = totalHours % 24
  const minutes = totalMinutes % 60

  if (days > 0) return `${days}d ${hours}h`
  if (totalHours > 0) return `${totalHours}h ${minutes}m`
  if (totalMinutes > 0) return `${totalMinutes}m`
  return "<1m"
}

/**
 * Compute ms until usage hits the limit at the current rate.
 * Returns null if ETA can't be computed or falls after reset.
 * Returns 0 when already at/over the limit.
 */
export function getLimitHitEtaMs({
  used,
  limit,
  resetsAtMs,
  periodDurationMs,
  nowMs,
}: {
  used: number
  limit: number
  resetsAtMs: number
  periodDurationMs: number
  nowMs: number
}): number | null {
  if (
    !Number.isFinite(used) ||
    !Number.isFinite(limit) ||
    !Number.isFinite(resetsAtMs) ||
    !Number.isFinite(periodDurationMs) ||
    !Number.isFinite(nowMs) ||
    limit <= 0 ||
    periodDurationMs <= 0
  ) {
    return null
  }
  if (used >= limit) return 0

  const periodStartMs = resetsAtMs - periodDurationMs
  const elapsedMs = nowMs - periodStartMs
  if (elapsedMs <= 0 || nowMs >= resetsAtMs) return null

  const usageRatePerMs = used / elapsedMs
  if (!Number.isFinite(usageRatePerMs) || usageRatePerMs <= 0) return null

  const msUntilLimit = (limit - used) / usageRatePerMs
  if (!Number.isFinite(msUntilLimit) || msUntilLimit <= 0) return 0

  const hitAtMs = nowMs + msUntilLimit
  if (hitAtMs >= resetsAtMs) return null

  return hitAtMs - nowMs
}

export function buildPaceDetailText({
  paceResult,
  used,
  limit,
  resetsAtMs,
  periodDurationMs,
  nowMs,
  displayMode,
}: {
  paceResult: PaceResult | null
  used: number
  limit: number
  resetsAtMs: number
  periodDurationMs: number
  nowMs: number
  displayMode: DisplayMode
}): string | null {
  if (!Number.isFinite(limit) || limit <= 0) return null

  // Limit reached — hard ceiling
  if (used >= limit) return LIMIT_REACHED

  if (!paceResult) return null

  // Behind pace → show ETA to hitting limit
  if (paceResult.status === "behind") {
    const etaMs = getLimitHitEtaMs({ used, limit, resetsAtMs, periodDurationMs, nowMs })
    if (etaMs != null && etaMs > 0) {
      const durationText = formatCompactDuration(etaMs)
      if (durationText) return `Limit in ${durationText}`
    }
    // Can't compute ETA — fall through to projected %
  }

  // Ahead / on-track (or behind without ETA) → show projected % at reset
  const projectedPercent = Math.min(100, Math.round((paceResult.projectedUsage / limit) * 100))
  const shownPercent = displayMode === "left" ? 100 - projectedPercent : projectedPercent
  const suffix = displayMode === "left" ? "left at reset" : "used at reset"
  return `${shownPercent}% ${suffix}`
}
