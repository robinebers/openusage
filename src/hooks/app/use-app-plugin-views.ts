import { useEffect, useMemo } from "react"
import type { ActiveView, NavPlugin } from "@/components/side-nav"
import { CODEX_GROUP_ID, isCodexAccountProviderId, type PluginMeta } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"
import type { PluginState } from "@/hooks/app/types"

export type AccountOption = { providerId: string; label: string }
export type DisplayPluginState = { meta: PluginMeta; sourceProviderId?: string } & PluginState

type UseAppPluginViewsArgs = {
  activeView: ActiveView
  setActiveView: (view: ActiveView) => void
  selectedCodexProviderId: string | null
  pluginSettings: PluginSettings | null
  pluginsMeta: PluginMeta[]
  pluginStates: Record<string, PluginState>
}

function emptyState(): PluginState {
  return { data: null, loading: false, error: null, lastManualRefreshAt: null, lastUpdatedAt: null }
}

export function useAppPluginViews({
  activeView,
  setActiveView,
  selectedCodexProviderId,
  pluginSettings,
  pluginsMeta,
  pluginStates,
}: UseAppPluginViewsArgs) {
  const enabledIds = useMemo(() => {
    if (!pluginSettings) return []
    const disabledSet = new Set(pluginSettings.disabled)
    return pluginSettings.order.filter((id) => !disabledSet.has(id))
  }, [pluginSettings])

  const metaById = useMemo(
    () => new Map(pluginsMeta.map((plugin) => [plugin.id, plugin])),
    [pluginsMeta]
  )

  const enabledCodexIds = useMemo(
    () => enabledIds.filter((id) => isCodexAccountProviderId(id) && metaById.has(id)),
    [enabledIds, metaById]
  )

  const activeCodexProviderId = useMemo(() => {
    if (selectedCodexProviderId && enabledCodexIds.includes(selectedCodexProviderId)) {
      return selectedCodexProviderId
    }
    return enabledCodexIds[0] ?? CODEX_GROUP_ID
  }, [enabledCodexIds, selectedCodexProviderId])

  const displayPlugins = useMemo<DisplayPluginState[]>(() => {
    if (!pluginSettings) return []
    const out: DisplayPluginState[] = []
    let addedCodex = false

    for (const id of enabledIds) {
      if (isCodexAccountProviderId(id)) {
        if (addedCodex) continue
        addedCodex = true
        const selectedMeta = metaById.get(activeCodexProviderId) ?? metaById.get(CODEX_GROUP_ID)
        if (!selectedMeta) continue
        const baseMeta = metaById.get(CODEX_GROUP_ID) ?? selectedMeta
        const state = pluginStates[activeCodexProviderId] ?? emptyState()
        out.push({
          ...state,
          sourceProviderId: activeCodexProviderId,
          meta: {
            ...baseMeta,
            id: CODEX_GROUP_ID,
            name: "Codex",
          },
        })
        continue
      }

      const meta = metaById.get(id)
      if (!meta) continue
      const state = pluginStates[id] ?? emptyState()
      out.push({ meta, ...state })
    }

    return out
  }, [activeCodexProviderId, enabledIds, metaById, pluginSettings, pluginStates])

  const navPlugins = useMemo<NavPlugin[]>(() => {
    if (!pluginSettings) return []
    const out: NavPlugin[] = []
    let addedCodex = false

    for (const id of enabledIds) {
      const plugin = metaById.get(id)
      if (!plugin) continue
      if (isCodexAccountProviderId(id)) {
        if (addedCodex) continue
        addedCodex = true
        const baseMeta = metaById.get(CODEX_GROUP_ID) ?? plugin
        out.push({
          id: CODEX_GROUP_ID,
          name: "Codex",
          iconUrl: baseMeta.iconUrl,
          brandColor: baseMeta.brandColor,
        })
        continue
      }
      out.push({
        id: plugin.id,
        name: plugin.name,
        iconUrl: plugin.iconUrl,
        brandColor: plugin.brandColor,
      })
    }

    return out
  }, [enabledIds, metaById, pluginSettings])

  const codexAccountOptions = useMemo<AccountOption[]>(() => {
    return enabledCodexIds.map((id) => {
      const meta = metaById.get(id)
      const state = pluginStates[id]
      return {
        providerId: id,
        label: state?.data?.plan ?? meta?.name ?? "Codex",
      }
    })
  }, [enabledCodexIds, metaById, pluginStates])

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
    codexAccountOptions,
  }
}
