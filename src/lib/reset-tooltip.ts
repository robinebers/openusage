const RESET_TOOLTIP_FORMATTER = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
  timeStyle: "short",
})

export function formatResetTooltipText(resetsAtIso: string): string | null {
  const resetsAtMs = Date.parse(resetsAtIso)
  if (!Number.isFinite(resetsAtMs)) return null
  return `Next reset: ${RESET_TOOLTIP_FORMATTER.format(resetsAtMs)}`
}
