import type { PluginOutput } from "@/lib/plugin-types"

export type PluginState = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
  lastManualRefreshAt: number | null
}
