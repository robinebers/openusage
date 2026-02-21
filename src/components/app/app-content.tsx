import { useShallow } from "zustand/react/shallow"
import { OverviewPage } from "@/pages/overview"
import { ProviderDetailPage } from "@/pages/provider-detail"
import { SettingsPage } from "@/pages/settings"
import { useAppDerivedStore } from "@/stores/app-derived-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useAppUiStore } from "@/stores/app-ui-store"
import type {
  AutoUpdateIntervalMinutes,
  DisplayMode,
  GlobalShortcut,
  ResetTimerDisplayMode,
  ThemeMode,
  TrayIconStyle,
} from "@/lib/settings"

export type AppContentProps = {
  onRetryPlugin: (id: string) => void
  onReorder: (orderedIds: string[]) => void
  onToggle: (id: string) => void
  onAutoUpdateIntervalChange: (value: AutoUpdateIntervalMinutes) => void
  onThemeModeChange: (mode: ThemeMode) => void
  onDisplayModeChange: (mode: DisplayMode) => void
  onResetTimerDisplayModeChange: (mode: ResetTimerDisplayMode) => void
  onResetTimerDisplayModeToggle: () => void
  onTrayIconStyleChange: (style: TrayIconStyle) => void
  onTrayShowPercentageChange: (value: boolean) => void
  onGlobalShortcutChange: (value: GlobalShortcut) => void
  onStartOnLoginChange: (value: boolean) => void
}

export function AppContent({
  onRetryPlugin,
  onReorder,
  onToggle,
  onAutoUpdateIntervalChange,
  onThemeModeChange,
  onDisplayModeChange,
  onResetTimerDisplayModeChange,
  onResetTimerDisplayModeToggle,
  onTrayIconStyleChange,
  onTrayShowPercentageChange,
  onGlobalShortcutChange,
  onStartOnLoginChange,
}: AppContentProps) {
  const { activeView } = useAppUiStore(
    useShallow((state) => ({
      activeView: state.activeView,
    }))
  )

  const {
    displayPlugins,
    settingsPlugins,
    navPlugins,
  } = useAppDerivedStore(
    useShallow((state) => ({
      displayPlugins: state.displayPlugins,
      settingsPlugins: state.settingsPlugins,
      navPlugins: state.navPlugins,
    }))
  )

  const {
    displayMode,
    resetTimerDisplayMode,
    autoUpdateInterval,
    trayIconStyle,
    trayShowPercentage,
    globalShortcut,
    themeMode,
    startOnLogin,
  } = useAppPreferencesStore(
    useShallow((state) => ({
      displayMode: state.displayMode,
      resetTimerDisplayMode: state.resetTimerDisplayMode,
      autoUpdateInterval: state.autoUpdateInterval,
      trayIconStyle: state.trayIconStyle,
      trayShowPercentage: state.trayShowPercentage,
      globalShortcut: state.globalShortcut,
      themeMode: state.themeMode,
      startOnLogin: state.startOnLogin,
    }))
  )

  const selectedPlugin =
    activeView === "home" || activeView === "settings"
      ? null
      : displayPlugins.find((plugin) => plugin.meta.id === activeView) ?? null

  if (activeView === "home") {
    return (
      <OverviewPage
        plugins={displayPlugins}
        onRetryPlugin={onRetryPlugin}
        displayMode={displayMode}
        resetTimerDisplayMode={resetTimerDisplayMode}
        onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
      />
    )
  }

  if (activeView === "settings") {
    return (
      <SettingsPage
        plugins={settingsPlugins}
        onReorder={onReorder}
        onToggle={onToggle}
        autoUpdateInterval={autoUpdateInterval}
        onAutoUpdateIntervalChange={onAutoUpdateIntervalChange}
        themeMode={themeMode}
        onThemeModeChange={onThemeModeChange}
        displayMode={displayMode}
        onDisplayModeChange={onDisplayModeChange}
        resetTimerDisplayMode={resetTimerDisplayMode}
        onResetTimerDisplayModeChange={onResetTimerDisplayModeChange}
        trayIconStyle={trayIconStyle}
        onTrayIconStyleChange={onTrayIconStyleChange}
        trayShowPercentage={trayShowPercentage}
        onTrayShowPercentageChange={onTrayShowPercentageChange}
        globalShortcut={globalShortcut}
        onGlobalShortcutChange={onGlobalShortcutChange}
        startOnLogin={startOnLogin}
        onStartOnLoginChange={onStartOnLoginChange}
        providerIconUrl={navPlugins[0]?.iconUrl}
      />
    )
  }

  const handleRetry = selectedPlugin
    ? () => onRetryPlugin(selectedPlugin.meta.id)
    : /* v8 ignore next */ undefined

  return (
    <ProviderDetailPage
      plugin={selectedPlugin}
      onRetry={handleRetry}
      displayMode={displayMode}
      resetTimerDisplayMode={resetTimerDisplayMode}
      onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
    />
  )
}
