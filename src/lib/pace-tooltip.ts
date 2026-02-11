import type { PaceResult, PaceStatus } from "@/lib/pace-status"
import type { DisplayMode } from "@/lib/settings"

export function getPaceStatusText(status: PaceStatus): string {
  return status === "ahead" ? "Plenty of room" : status === "on-track" ? "Right on target" : "Will run out"
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

export function buildPaceDetailText({
  paceResult,
  used,
  limit,
  periodDurationMs,
  resetsAtMs,
  nowMs,
  displayMode,
}: {
  paceResult: PaceResult | null
  used: number
  limit: number
  periodDurationMs: number
  resetsAtMs: number
  nowMs: number
  displayMode: DisplayMode
}): string | null {
  if (!paceResult || !Number.isFinite(limit) || limit <= 0 || paceResult.projectedUsage === 0) return null

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
