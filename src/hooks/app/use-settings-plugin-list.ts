import { useMemo } from "react"
import type { PluginMeta } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"

export type SettingsPluginState = {
  id: string
  name: string
  enabled: boolean
}

type UseSettingsPluginListArgs = {
  pluginSettings: PluginSettings | null
  pluginsMeta: PluginMeta[]
}

export function useSettingsPluginList({ pluginSettings, pluginsMeta }: UseSettingsPluginListArgs) {
  return useMemo<SettingsPluginState[]>(() => {
    if (!pluginSettings) return []
    const pluginMap = new Map(pluginsMeta.map((plugin) => [plugin.id, plugin]))

    return pluginSettings.order
      .map((id) => {
        const meta = pluginMap.get(id)
        if (!meta) return null
        return {
          id,
          name: meta.name,
          enabled: !pluginSettings.disabled.includes(id),
        }
      })
      .filter((plugin): plugin is SettingsPluginState => Boolean(plugin))
  }, [pluginSettings, pluginsMeta])
}
