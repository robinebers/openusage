import type { ResetTimerDisplayMode } from "@/lib/settings"
import { formatCompactDuration } from "@/lib/pace-tooltip"

const RESET_TIME_FORMATTER = new Intl.DateTimeFormat(undefined, {
  hour: "numeric",
  minute: "2-digit",
})

const RESET_MONTH_FORMATTER = new Intl.DateTimeFormat(undefined, {
  month: "short",
})

export const RESET_SOON_THRESHOLD_MS = 5 * 60 * 1000

function parseResetTimestamp(resetsAtIso: string): number | null {
  const resetsAtMs = Date.parse(resetsAtIso)
  return Number.isFinite(resetsAtMs) ? resetsAtMs : null
}

function getLocalDayIndex(timestampMs: number): number {
  const date = new Date(timestampMs)
  return Math.floor(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86_400_000)
}

function getEnglishOrdinalSuffix(day: number): string {
  const mod100 = day % 100
  if (mod100 >= 11 && mod100 <= 13) return "th"
  const mod10 = day % 10
  if (mod10 === 1) return "st"
  if (mod10 === 2) return "nd"
  if (mod10 === 3) return "rd"
  return "th"
}

function formatMonthDayWithOrdinal(timestampMs: number): string {
  const date = new Date(timestampMs)
  const monthText = RESET_MONTH_FORMATTER.format(date)
  const day = date.getDate()
  return `${monthText} ${day}${getEnglishOrdinalSuffix(day)}`
}

export function formatResetRelativeLabel(nowMs: number, resetsAtIso: string): string | null {
  const resetsAtMs = parseResetTimestamp(resetsAtIso)
  if (resetsAtMs === null) return null
  const deltaMs = resetsAtMs - nowMs
  if (deltaMs < RESET_SOON_THRESHOLD_MS) return "Resets soon"
  const durationText = formatCompactDuration(deltaMs)
  return durationText ? `Resets in ${durationText}` : null
}

export function formatResetAbsoluteLabel(nowMs: number, resetsAtIso: string): string | null {
  const resetsAtMs = parseResetTimestamp(resetsAtIso)
  if (resetsAtMs === null) return null
  if (resetsAtMs - nowMs <= 0) return "Resets soon"
  const dayDiff = getLocalDayIndex(resetsAtMs) - getLocalDayIndex(nowMs)
  const timeText = RESET_TIME_FORMATTER.format(resetsAtMs)
  if (dayDiff <= 0) return `Resets today at ${timeText}`
  if (dayDiff === 1) return `Resets tomorrow at ${timeText}`
  const dateText = formatMonthDayWithOrdinal(resetsAtMs)
  return `Resets ${dateText} at ${timeText}`
}

export function formatResetTooltipText({
  nowMs,
  resetsAtIso,
  visibleMode,
}: {
  nowMs: number
  resetsAtIso: string
  visibleMode: ResetTimerDisplayMode
}): string | null {
  return visibleMode === "absolute"
    ? formatResetRelativeLabel(nowMs, resetsAtIso)
    : formatResetAbsoluteLabel(nowMs, resetsAtIso)
}
