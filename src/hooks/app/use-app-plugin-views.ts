import { useEffect, useMemo } from "react"
import type { ActiveView, NavPlugin } from "@/components/side-nav"
import type { PluginMeta } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"
import type { PluginState } from "@/hooks/app/types"

export type DisplayPluginState = { meta: PluginMeta } & PluginState

type UseAppPluginViewsArgs = {
  activeView: ActiveView
  setActiveView: (view: ActiveView) => void
  pluginSettings: PluginSettings | null
  pluginsMeta: PluginMeta[]
  pluginStates: Record<string, PluginState>
}

export function useAppPluginViews({
  activeView,
  setActiveView,
  pluginSettings,
  pluginsMeta,
  pluginStates,
}: UseAppPluginViewsArgs) {
  const displayPlugins = useMemo<DisplayPluginState[]>(() => {
    if (!pluginSettings) return []
    const disabledSet = new Set(pluginSettings.disabled)
    const metaById = new Map(pluginsMeta.map((plugin) => [plugin.id, plugin]))

    return pluginSettings.order
      .filter((id) => !disabledSet.has(id))
      .map((id) => {
        const meta = metaById.get(id)
        if (!meta) return null
        const state =
          pluginStates[id] ?? { data: null, loading: false, error: null, lastManualRefreshAt: null }
        return { meta, ...state }
      })
      .filter((plugin): plugin is DisplayPluginState => Boolean(plugin))
  }, [pluginSettings, pluginStates, pluginsMeta])

  const navPlugins = useMemo<NavPlugin[]>(() => {
    if (!pluginSettings) return []
    const disabledSet = new Set(pluginSettings.disabled)
    const metaById = new Map(pluginsMeta.map((plugin) => [plugin.id, plugin]))

    return pluginSettings.order
      .filter((id) => !disabledSet.has(id))
      .map((id) => metaById.get(id))
      .filter((plugin): plugin is PluginMeta => Boolean(plugin))
      .map((plugin) => ({
        id: plugin.id,
        name: plugin.name,
        iconUrl: plugin.iconUrl,
        brandColor: plugin.brandColor,
      }))
  }, [pluginSettings, pluginsMeta])

  useEffect(() => {
    if (activeView === "home" || activeView === "settings") return
    if (!pluginSettings) return
    const isKnownPlugin = pluginsMeta.some((plugin) => plugin.id === activeView)
    if (!isKnownPlugin) return
    const isStillEnabled = navPlugins.some((plugin) => plugin.id === activeView)
    if (!isStillEnabled) {
      setActiveView("home")
    }
  }, [activeView, navPlugins, pluginSettings, pluginsMeta, setActiveView])

  const selectedPlugin = useMemo(() => {
    if (activeView === "home" || activeView === "settings") return null
    return displayPlugins.find((plugin) => plugin.meta.id === activeView) ?? null
  }, [activeView, displayPlugins])

  return {
    displayPlugins,
    navPlugins,
    selectedPlugin,
  }
}
