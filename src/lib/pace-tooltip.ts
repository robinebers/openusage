import type { PaceResult, PaceStatus } from "@/lib/pace-status"

export function getPaceStatusText(status: PaceStatus): string {
  return status === "ahead" ? "Ahead of pace" : status === "on-track" ? "On track" : "Using fast"
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

export function getLimitHitEtaText({
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
}): string | null {
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
  if (used >= limit) return "at/over 100% now"

  const periodStartMs = resetsAtMs - periodDurationMs
  const elapsedMs = nowMs - periodStartMs
  if (elapsedMs <= 0 || nowMs >= resetsAtMs) return null

  const usageRatePerMs = used / elapsedMs
  if (!Number.isFinite(usageRatePerMs) || usageRatePerMs <= 0) return null

  const msUntilLimit = (limit - used) / usageRatePerMs
  if (!Number.isFinite(msUntilLimit) || msUntilLimit <= 0) return "at/over 100% now"

  const hitAtMs = nowMs + msUntilLimit
  if (hitAtMs >= resetsAtMs) return null

  const durationText = formatCompactDuration(hitAtMs - nowMs)
  return durationText ? `hits 100% in ${durationText}` : null
}

export function buildPaceDetailText({
  paceResult,
  used,
  limit,
  resetsAtMs,
  periodDurationMs,
  nowMs,
}: {
  paceResult: PaceResult | null
  used: number
  limit: number
  resetsAtMs: number
  periodDurationMs: number
  nowMs: number
}): string | null {
  if (!paceResult || !Number.isFinite(limit) || limit <= 0) return null

  const projectedPercent = Math.round((paceResult.projectedUsage / limit) * 100)
  if (projectedPercent <= 100) return `projected ${projectedPercent}% by reset`

  const etaText = getLimitHitEtaText({
    used,
    limit,
    resetsAtMs,
    periodDurationMs,
    nowMs,
  })
  return etaText ?? `projected ${projectedPercent}% by reset`
}
