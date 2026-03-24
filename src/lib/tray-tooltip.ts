import type { PluginMeta } from "@/lib/plugin-types"
import type { TrayPrimaryBar } from "@/lib/tray-primary-progress"

/**
 * Formats a fraction (0.0 - 1.0) into a percentage string (0% - 100%).
 */
export function formatTrayPercentText(fraction: number | undefined): string {
  if (typeof fraction !== "number" || !Number.isFinite(fraction)) return "--%"
  const clampedFraction = Math.max(0, Math.min(1, fraction))
  return `${Math.round(clampedFraction * 100)}%`
}

/**
 * Creates a multi-line tooltip string for the tray icon.
 * Lists the app name followed by enabled plugins and their usage percentages.
 */
export function formatTrayTooltip(bars: TrayPrimaryBar[], pluginsMeta: PluginMeta[]): string {
  const lines = ["OpenUsage"]
  if (bars.length === 0) return lines[0]!
  
  const metaById = new Map(pluginsMeta.map((p) => [p.id, p]))
  for (const bar of bars) {
    const meta = metaById.get(bar.id)
    if (meta) {
      const percent = formatTrayPercentText(bar.fraction)
      lines.push(`${meta.name}: ${percent}`)
    }
  }
  return lines.join("\n")
}
