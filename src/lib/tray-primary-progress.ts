import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"
import { DEFAULT_DISPLAY_MODE, type DisplayMode } from "@/lib/settings"
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

function getShownAmount(line: ProgressLine, displayMode: DisplayMode): number {
  return displayMode === "used" ? line.used : line.limit - line.used
}

function getPerplexityAggregateFraction(data: PluginOutput, displayMode: DisplayMode): number | undefined {
  const perplexityBucketLabels = new Set(["Pro", "Research", "Labs"])
  const bucketLines = data.lines.filter(
    (line): line is ProgressLine =>
      isProgressLine(line) &&
      perplexityBucketLabels.has(line.label) &&
      Number.isFinite(line.limit) &&
      line.limit > 0
  )
  if (bucketLines.length === 0) return undefined

  const totalLimit = bucketLines.reduce((sum, line) => sum + line.limit, 0)
  if (totalLimit <= 0) return undefined

  const totalShown = bucketLines.reduce((sum, line) => sum + getShownAmount(line, displayMode), 0)
  return clamp01(totalShown / totalLimit)
}

export function getTrayPrimaryBars(args: {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginState | undefined>
  maxBars?: number
  displayMode?: DisplayMode
}): TrayPrimaryBar[] {
  const { pluginsMeta, pluginSettings, pluginStates, maxBars = 4, displayMode = DEFAULT_DISPLAY_MODE } = args
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
      if (id === "perplexity") {
        fraction = getPerplexityAggregateFraction(data, displayMode)
      }

      // Find first candidate that exists in runtime data
      if (fraction === undefined) {
        const primaryLabel = meta.primaryCandidates.find((label) =>
          data.lines.some((line) => isProgressLine(line) && line.label === label)
        )
        if (primaryLabel) {
          const primaryLine = data.lines.find(
            (line): line is ProgressLine =>
              isProgressLine(line) && line.label === primaryLabel
          )
          if (primaryLine && primaryLine.limit > 0) {
            fraction = clamp01(getShownAmount(primaryLine, displayMode) / primaryLine.limit)
          }
        }
      }
    }

    out.push({ id, fraction })
    if (out.length >= maxBars) break
  }

  return out
}
