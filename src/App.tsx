import { useCallback, useEffect, useRef } from "react"
import { useShallow } from "zustand/react/shallow"
import { AppShell } from "@/components/app/app-shell"
import { useAppPluginViews } from "@/hooks/app/use-app-plugin-views"
import { useProbe } from "@/hooks/app/use-probe"
import { useSettingsBootstrap } from "@/hooks/app/use-settings-bootstrap"
import { useSettingsDisplayActions } from "@/hooks/app/use-settings-display-actions"
import { useSettingsPluginActions } from "@/hooks/app/use-settings-plugin-actions"
import { useSettingsPluginList } from "@/hooks/app/use-settings-plugin-list"
import { useSettingsSystemActions } from "@/hooks/app/use-settings-system-actions"
import { useSettingsTheme } from "@/hooks/app/use-settings-theme"
import { useSettingsTrayActions } from "@/hooks/app/use-settings-tray-actions"
import { useTrayIcon } from "@/hooks/app/use-tray-icon"
import { useAppDerivedStore } from "@/stores/app-derived-store"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"
import { useAppUiStore } from "@/stores/app-ui-store"

const TRAY_PROBE_DEBOUNCE_MS = 500

function App() {
  const {
    activeView,
    setActiveView,
  } = useAppUiStore(
    useShallow((state) => ({
      activeView: state.activeView,
      setActiveView: state.setActiveView,
    }))
  )

  const {
    pluginsMeta,
    setPluginsMeta,
    pluginSettings,
    setPluginSettings,
  } = useAppPluginStore(
    useShallow((state) => ({
      pluginsMeta: state.pluginsMeta,
      setPluginsMeta: state.setPluginsMeta,
      pluginSettings: state.pluginSettings,
      setPluginSettings: state.setPluginSettings,
    }))
  )

  const {
    autoUpdateInterval,
    setAutoUpdateInterval,
    themeMode,
    setThemeMode,
    displayMode,
    setDisplayMode,
    resetTimerDisplayMode,
    setResetTimerDisplayMode,
    trayIconStyle,
    setTrayIconStyle,
    trayShowPercentage,
    setTrayShowPercentage,
    setGlobalShortcut,
    setStartOnLogin,
  } = useAppPreferencesStore(
    useShallow((state) => ({
      autoUpdateInterval: state.autoUpdateInterval,
      setAutoUpdateInterval: state.setAutoUpdateInterval,
      themeMode: state.themeMode,
      setThemeMode: state.setThemeMode,
      displayMode: state.displayMode,
      setDisplayMode: state.setDisplayMode,
      resetTimerDisplayMode: state.resetTimerDisplayMode,
      setResetTimerDisplayMode: state.setResetTimerDisplayMode,
      trayIconStyle: state.trayIconStyle,
      setTrayIconStyle: state.setTrayIconStyle,
      trayShowPercentage: state.trayShowPercentage,
      setTrayShowPercentage: state.setTrayShowPercentage,
      setGlobalShortcut: state.setGlobalShortcut,
      setStartOnLogin: state.setStartOnLogin,
    }))
  )

  const {
    setPluginViews,
    setSettingsPlugins,
    setAutoUpdateNextAt: setStoreAutoUpdateNextAt,
  } = useAppDerivedStore(
    useShallow((state) => ({
      setPluginViews: state.setPluginViews,
      setSettingsPlugins: state.setSettingsPlugins,
      setAutoUpdateNextAt: state.setAutoUpdateNextAt,
    }))
  )

  const scheduleProbeTrayUpdateRef = useRef<() => void>(() => {})
  const handleProbeResult = useCallback(() => {
    scheduleProbeTrayUpdateRef.current()
  }, [])

  const {
    pluginStates,
    setLoadingForPlugins,
    setErrorForPlugins,
    startBatch,
    autoUpdateNextAt,
    setAutoUpdateNextAt,
    handleRetryPlugin,
    handleRefreshAll,
  } = useProbe({
    pluginSettings,
    autoUpdateInterval,
    onProbeResult: handleProbeResult,
  })

  const { scheduleTrayIconUpdate } = useTrayIcon({
    pluginsMeta,
    pluginSettings,
    pluginStates,
    displayMode,
    trayIconStyle,
    trayShowPercentage,
  })

  useEffect(() => {
    scheduleProbeTrayUpdateRef.current = () => {
      scheduleTrayIconUpdate("probe", TRAY_PROBE_DEBOUNCE_MS)
    }
  }, [scheduleTrayIconUpdate])

  const { applyStartOnLogin } = useSettingsBootstrap({
    setPluginSettings,
    setPluginsMeta,
    setAutoUpdateInterval,
    setThemeMode,
    setDisplayMode,
    setResetTimerDisplayMode,
    setTrayIconStyle,
    setTrayShowPercentage,
    setGlobalShortcut,
    setStartOnLogin,
    setLoadingForPlugins,
    setErrorForPlugins,
    startBatch,
  })

  useSettingsTheme(themeMode)

  const {
    handleThemeModeChange,
    handleDisplayModeChange,
    handleResetTimerDisplayModeChange,
    handleResetTimerDisplayModeToggle,
  } = useSettingsDisplayActions({
    setThemeMode,
    setDisplayMode,
    resetTimerDisplayMode,
    setResetTimerDisplayMode,
    scheduleTrayIconUpdate,
  })

  const {
    handleTrayIconStyleChange,
    handleTrayShowPercentageChange,
  } = useSettingsTrayActions({
    setTrayIconStyle,
    trayShowPercentage,
    setTrayShowPercentage,
    scheduleTrayIconUpdate,
  })

  const {
    handleAutoUpdateIntervalChange,
    handleGlobalShortcutChange,
    handleStartOnLoginChange,
  } = useSettingsSystemActions({
    pluginSettings,
    setAutoUpdateInterval,
    setAutoUpdateNextAt,
    setGlobalShortcut,
    setStartOnLogin,
    applyStartOnLogin,
  })

  const {
    handleReorder,
    handleToggle,
  } = useSettingsPluginActions({
    pluginSettings,
    setPluginSettings,
    setLoadingForPlugins,
    setErrorForPlugins,
    startBatch,
    scheduleTrayIconUpdate,
  })

  const settingsPlugins = useSettingsPluginList({
    pluginSettings,
    pluginsMeta,
  })

  const { displayPlugins, navPlugins } = useAppPluginViews({
    activeView,
    setActiveView,
    pluginSettings,
    pluginsMeta,
    pluginStates,
  })

  useEffect(() => {
    setPluginViews({ displayPlugins, navPlugins })
  }, [displayPlugins, navPlugins, setPluginViews])

  useEffect(() => {
    setSettingsPlugins(settingsPlugins)
  }, [settingsPlugins, setSettingsPlugins])

  useEffect(() => {
    setStoreAutoUpdateNextAt(autoUpdateNextAt)
  }, [autoUpdateNextAt, setStoreAutoUpdateNextAt])

  return (
    <AppShell
      onRefreshAll={handleRefreshAll}
      appContentProps={{
        onRetryPlugin: handleRetryPlugin,
        onReorder: handleReorder,
        onToggle: handleToggle,
        onAutoUpdateIntervalChange: handleAutoUpdateIntervalChange,
        onThemeModeChange: handleThemeModeChange,
        onDisplayModeChange: handleDisplayModeChange,
        onResetTimerDisplayModeChange: handleResetTimerDisplayModeChange,
        onResetTimerDisplayModeToggle: handleResetTimerDisplayModeToggle,
        onTrayIconStyleChange: handleTrayIconStyleChange,
        onTrayShowPercentageChange: handleTrayShowPercentageChange,
        onGlobalShortcutChange: handleGlobalShortcutChange,
        onStartOnLoginChange: handleStartOnLoginChange,
      }}
    />
  )
}

export { App }
