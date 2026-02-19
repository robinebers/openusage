import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"
import {
  DEFAULT_DISPLAY_MODE,
  DEFAULT_TRAY_METRIC_PREFERENCE,
  type DisplayMode,
  type TrayMetricPreference,
} from "@/lib/settings"
import { clamp01 } from "@/lib/utils"

type PluginState = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
}

export type TrayPrimaryBar = {
  id: string
  fraction?: number
}

type ProgressLine = Extract<
  PluginOutput["lines"][number],
  { type: "progress"; label: string; used: number; limit: number }
>

function isProgressLine(line: PluginOutput["lines"][number]): line is ProgressLine {
  return line.type === "progress"
}

/**
 * Reorder candidates based on user preference.
 * If preference is "weekly", move weekly-related candidates to the front.
 */
function reorderCandidatesByPreference(
  candidates: string[],
  preference?: TrayMetricPreference
): string[] {
  if (!preference || preference === "session") {
    return candidates // Keep original order
  }

  // Move "weekly" to front, keep other candidates in order
  const weekly = candidates.filter((c) => c.toLowerCase().includes("weekly"))
  const others = candidates.filter((c) => !c.toLowerCase().includes("weekly"))
  return [...weekly, ...others]
}

export function getTrayPrimaryBars(args: {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginState | undefined>
  maxBars?: number
  displayMode?: DisplayMode
  metricPreference?: TrayMetricPreference
}): TrayPrimaryBar[] {
  const {
    pluginsMeta,
    pluginSettings,
    pluginStates,
    maxBars = 4,
    displayMode = DEFAULT_DISPLAY_MODE,
    metricPreference = DEFAULT_TRAY_METRIC_PREFERENCE,
  } = args
  if (!pluginSettings) return []

  const metaById = new Map(pluginsMeta.map((p) => [p.id, p]))
  const disabled = new Set(pluginSettings.disabled)

  const out: TrayPrimaryBar[] = []
  for (const id of pluginSettings.order) {
    if (disabled.has(id)) continue
    const meta = metaById.get(id)
    if (!meta) continue
    
    // Skip if no primary candidates defined
    if (!meta.primaryCandidates || meta.primaryCandidates.length === 0) continue

    const state = pluginStates[id]
    const data = state?.data ?? null

    let fraction: number | undefined
    if (data) {
      // Reorder candidates based on user preference
      const orderedCandidates = reorderCandidatesByPreference(meta.primaryCandidates, metricPreference)

      // Find first candidate that exists in runtime data
      const primaryLabel = orderedCandidates.find((label) =>
        data.lines.some((line) => isProgressLine(line) && line.label === label)
      )
      if (primaryLabel) {
        const primaryLine = data.lines.find(
          (line): line is ProgressLine =>
            isProgressLine(line) && line.label === primaryLabel
        )
        if (primaryLine && primaryLine.limit > 0) {
          const shownAmount =
            displayMode === "used"
              ? primaryLine.used
              : primaryLine.limit - primaryLine.used
          fraction = clamp01(shownAmount / primaryLine.limit)
        }
      }
    }

    out.push({ id, fraction })
    if (out.length >= maxBars) break
  }

  return out
}

