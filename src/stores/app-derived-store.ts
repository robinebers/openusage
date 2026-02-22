import { create } from "zustand"
import type { NavPlugin } from "@/components/side-nav"
import type { DisplayPluginState } from "@/hooks/app/use-app-plugin-views"
import type { SettingsPluginState } from "@/hooks/app/use-settings-plugin-list"

type AppDerivedStore = {
  navPlugins: NavPlugin[]
  displayPlugins: DisplayPluginState[]
  settingsPlugins: SettingsPluginState[]
  autoUpdateNextAt: number | null
  setPluginViews: (value: {
    navPlugins: NavPlugin[]
    displayPlugins: DisplayPluginState[]
  }) => void
  setSettingsPlugins: (value: SettingsPluginState[]) => void
  setAutoUpdateNextAt: (value: number | null) => void
  resetState: () => void
}

const initialState = {
  navPlugins: [] as NavPlugin[],
  displayPlugins: [] as DisplayPluginState[],
  settingsPlugins: [] as SettingsPluginState[],
  autoUpdateNextAt: null as number | null,
}

export const useAppDerivedStore = create<AppDerivedStore>((set) => ({
  ...initialState,
  setPluginViews: ({ displayPlugins, navPlugins }) => set({ displayPlugins, navPlugins }),
  setSettingsPlugins: (value) => set({ settingsPlugins: value }),
  setAutoUpdateNextAt: (value) => set({ autoUpdateNextAt: value }),
  resetState: () => set(initialState),
}))
