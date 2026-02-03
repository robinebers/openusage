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
    const primaryLabel = meta.primaryProgressLabel ?? null
    if (!primaryLabel) continue

    const state = pluginStates[id]
    const data = state?.data ?? null

    let fraction: number | undefined
    if (data) {
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

    out.push({ id, fraction })
    if (out.length >= maxBars) break
  }

  return out
}

