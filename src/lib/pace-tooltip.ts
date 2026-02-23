import type { PaceResult, PaceStatus } from "@/lib/pace-status"
import type { ProgressFormat } from "@/lib/plugin-types"
import type { DisplayMode } from "@/lib/settings"
import { formatCountNumber, formatFixedPrecisionNumber } from "@/lib/utils"

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

function getRunsOutDurationText({
  paceResult,
  used,
  limit,
  periodDurationMs,
  resetsAtMs,
  nowMs,
}: {
  paceResult: PaceResult | null
  used: number
  limit: number
  periodDurationMs: number
  resetsAtMs: number
  nowMs: number
}): string | null {
  if (!paceResult || paceResult.status !== "behind") return null
  const rate = paceResult.projectedUsage / periodDurationMs
  if (rate <= 0) return null
  const etaMs = (limit - used) / rate
  const remainingMs = resetsAtMs - nowMs
  if (etaMs <= 0 || etaMs >= remainingMs) return null
  return formatCompactDuration(etaMs)
}

/**
 * ETA text for when usage will hit the limit, e.g. "Runs out in 4d 5h".
 * Returns null if not behind pace or ETA can't be computed.
 */
export function formatRunsOutText({
  paceResult,
  used,
  limit,
  periodDurationMs,
  resetsAtMs,
  nowMs,
}: {
  paceResult: PaceResult | null
  used: number
  limit: number
  periodDurationMs: number
  resetsAtMs: number
  nowMs: number
}): string | null {
  const durationText = getRunsOutDurationText({ paceResult, used, limit, periodDurationMs, resetsAtMs, nowMs })
  return durationText ? `Runs out in ${durationText}` : null
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

  if (paceResult.status === "behind") {
    const durationText = getRunsOutDurationText({ paceResult, used, limit, periodDurationMs, resetsAtMs, nowMs })
    if (durationText) return `Limit in ${durationText}`
  }

  // Show projected % at reset (clamped to 100%)
  const projectedPercent = Math.min(100, Math.round((paceResult.projectedUsage / limit) * 100))
  const shownPercent = displayMode === "left" ? 100 - projectedPercent : projectedPercent
  const suffix = displayMode === "left" ? "left at reset" : "used at reset"
  return `${shownPercent}% ${suffix}`
}

export function formatDeficitText(
  deficit: number,
  format: ProgressFormat,
  displayMode: DisplayMode
): string | null {
  if (!Number.isFinite(deficit) || deficit <= 0) return null

  const suffix = displayMode === "left" ? "short" : "in deficit"
  if (format.kind === "percent") {
    const roundedPercent = Math.round(deficit)
    return roundedPercent > 0 ? `${roundedPercent}% ${suffix}` : null
  }

  const roundedToCents = Math.round(deficit * 100) / 100
  if (roundedToCents <= 0) return null

  if (format.kind === "dollars") return `$${formatFixedPrecisionNumber(roundedToCents)} ${suffix}`
  return `${formatCountNumber(roundedToCents)} ${format.suffix} ${suffix}`
}
