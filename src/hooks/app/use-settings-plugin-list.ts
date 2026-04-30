import { useMemo } from "react"
import { CODEX_GROUP_ID, isCodexAccountProviderId, type PluginMeta } from "@/lib/plugin-types"
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
    const disabledSet = new Set(pluginSettings.disabled)
    let addedCodex = false
    const codexIds = pluginSettings.order.filter((id) => isCodexAccountProviderId(id) && pluginMap.has(id))
    const codexEnabled = codexIds.some((id) => !disabledSet.has(id))

    const plugins: SettingsPluginState[] = []
    for (const id of pluginSettings.order) {
      const meta = pluginMap.get(id)
      if (!meta) continue

      if (isCodexAccountProviderId(id)) {
        if (addedCodex) continue
        addedCodex = true
        const baseMeta = pluginMap.get(CODEX_GROUP_ID) ?? meta
        plugins.push({
          id: CODEX_GROUP_ID,
          name: baseMeta.name,
          enabled: codexEnabled,
        })
        continue
      }

      plugins.push({
        id,
        name: meta.name,
        enabled: !disabledSet.has(id),
      })
    }

    return plugins
  }, [pluginSettings, pluginsMeta])
}
