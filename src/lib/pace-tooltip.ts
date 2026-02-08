import type { PaceResult, PaceStatus } from "@/lib/pace-status"
import type { DisplayMode } from "@/lib/settings"

export function getPaceStatusText(status: PaceStatus): string {
  return status === "ahead" ? "Behind pace" : status === "on-track" ? "On track" : "Ahead of pace"
}

export function getPaceStatusLabel(status: PaceStatus): string {
  return status === "ahead" ? "Behind" : status === "on-track" ? "On track" : "Ahead"
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

function getReservePercent({
  used,
  limit,
  periodDurationMs,
  resetsAtMs,
  nowMs,
}: {
  used: number
  limit: number
  periodDurationMs: number
  resetsAtMs: number
  nowMs: number
}): number | null {
  if (
    !Number.isFinite(used) ||
    !Number.isFinite(limit) ||
    !Number.isFinite(periodDurationMs) ||
    !Number.isFinite(resetsAtMs) ||
    !Number.isFinite(nowMs)
  ) {
    return null
  }

  if (limit <= 0 || periodDurationMs <= 0) return null

  const periodStartMs = resetsAtMs - periodDurationMs
  const elapsedMs = nowMs - periodStartMs
  if (elapsedMs <= 0 || nowMs >= resetsAtMs) return null

  const elapsedFraction = elapsedMs / periodDurationMs
  if (elapsedFraction < 0.05) return null

  const expectedUsage = elapsedFraction * limit
  const reservePercent = Math.round(((expectedUsage - used) / limit) * 100)
  return reservePercent > 0 ? reservePercent : null
}

export function buildPaceDetailText({
  paceResult,
  used,
  limit,
  periodDurationMs,
  resetsAtMs,
  nowMs,
  displayMode,
  showReservePercent = false,
}: {
  paceResult: PaceResult | null
  used: number
  limit: number
  periodDurationMs: number
  resetsAtMs: number
  nowMs: number
  displayMode: DisplayMode
  showReservePercent?: boolean
}): string | null {
  if (!paceResult || !Number.isFinite(limit) || limit <= 0) return null

  if (showReservePercent && paceResult.status === "ahead") {
    const reservePercent = getReservePercent({
      used,
      limit,
      periodDurationMs,
      resetsAtMs,
      nowMs,
    })
    if (reservePercent !== null) return `${reservePercent}% in reserve`
    if (paceResult.projectedUsage === 0) return null
  }

  if (paceResult.projectedUsage === 0) return null

  // Behind pace → show ETA to hitting limit (derived from projectedUsage)
  if (paceResult.status === "behind") {
    const rate = paceResult.projectedUsage / periodDurationMs
    if (rate > 0) {
      const etaMs = (limit - used) / rate
      const remainingMs = resetsAtMs - nowMs
      if (etaMs > 0 && etaMs < remainingMs) {
        const durationText = formatCompactDuration(etaMs)
        if (durationText) return `Limit in ${durationText}`
      }
    }
    // Can't compute ETA — fall through to projected %
  }

  // Show projected % at reset (clamped to 100%)
  const projectedPercent = Math.min(100, Math.round((paceResult.projectedUsage / limit) * 100))
  const shownPercent = displayMode === "left" ? 100 - projectedPercent : projectedPercent
  const suffix = displayMode === "left" ? "left at reset" : "used at reset"
  return `${shownPercent}% ${suffix}`
}
