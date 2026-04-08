import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import type { PluginSettings, WeeklyWarningThresholdPercent } from "@/lib/settings"
import {
  DEFAULT_DISPLAY_MODE,
  DEFAULT_WEEKLY_WARNING_THRESHOLD_PERCENT,
  type DisplayMode,
} from "@/lib/settings"
import { selectTrayPrimaryMetric, type TrayAlertSeverity } from "@/lib/tray-alert"
import { clamp01 } from "@/lib/utils"

type PluginState = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
}

export type TrayPrimaryBar = {
  id: string
  label?: string
  fraction?: number
  warningSeverity: TrayAlertSeverity
}

export function getTrayPrimaryBars(args: {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginState | undefined>
  maxBars?: number
  displayMode?: DisplayMode
  pluginId?: string
  weeklyWarningThresholdPercent?: WeeklyWarningThresholdPercent
}): TrayPrimaryBar[] {
  const {
    pluginsMeta,
    pluginSettings,
    pluginStates,
    maxBars = 4,
    displayMode = DEFAULT_DISPLAY_MODE,
    pluginId,
    weeklyWarningThresholdPercent = DEFAULT_WEEKLY_WARNING_THRESHOLD_PERCENT,
  } = args
  if (!pluginSettings) return []

  const metaById = new Map(pluginsMeta.map((p) => [p.id, p]))
  const disabled = new Set(pluginSettings.disabled)
  const orderedIds = pluginId
    ? [pluginId]
    : pluginSettings.order

  const out: TrayPrimaryBar[] = []
  for (const id of orderedIds) {
    if (disabled.has(id)) continue
    const meta = metaById.get(id)
    if (!meta) continue
    
    // Skip if no primary candidates defined
    if (!meta.primaryCandidates || meta.primaryCandidates.length === 0) continue

    const state = pluginStates[id]
    const data = state?.data ?? null

    const { line: primaryLine, warningSeverity } = selectTrayPrimaryMetric({
      meta,
      data,
      weeklyWarningThresholdPercent,
    })

    let fraction: number | undefined
    if (primaryLine && primaryLine.limit > 0) {
      const shownAmount =
        displayMode === "used"
          ? primaryLine.used
          : primaryLine.limit - primaryLine.used
      fraction = clamp01(shownAmount / primaryLine.limit)
    }

    out.push({
      id,
      label: primaryLine?.label,
      fraction,
      warningSeverity,
    })
    if (out.length >= maxBars) break
  }

  return out
}
