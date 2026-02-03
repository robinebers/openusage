import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { getCurrentWindow, PhysicalSize, currentMonitor } from "@tauri-apps/api/window"
import { getVersion } from "@tauri-apps/api/app"
import { resolveResource } from "@tauri-apps/api/path"
import { TrayIcon } from "@tauri-apps/api/tray"
import { SideNav, type ActiveView } from "@/components/side-nav"
import { PanelFooter } from "@/components/panel-footer"
import { OverviewPage } from "@/pages/overview"
import { ProviderDetailPage } from "@/pages/provider-detail"
import { SettingsPage } from "@/pages/settings"
import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import { getTrayIconSizePx, renderTrayBarsIcon } from "@/lib/tray-bars-icon"
import { getTrayPrimaryBars } from "@/lib/tray-primary-progress"
import { useProbeEvents } from "@/hooks/use-probe-events"
import { useAppUpdate } from "@/hooks/use-app-update"
import {
  arePluginSettingsEqual,
  DEFAULT_AUTO_UPDATE_INTERVAL,
  DEFAULT_THEME_MODE,
  getEnabledPluginIds,
  loadAutoUpdateInterval,
  loadPluginSettings,
  loadThemeMode,
  normalizePluginSettings,
  saveAutoUpdateInterval,
  savePluginSettings,
  saveThemeMode,
  type AutoUpdateIntervalMinutes,
  type PluginSettings,
  type ThemeMode,
} from "@/lib/settings"

const PANEL_WIDTH = 400;
const MAX_HEIGHT_FALLBACK_PX = 600;
const MAX_HEIGHT_FRACTION_OF_MONITOR = 0.8;
const ARROW_OVERHEAD_PX = 37; // .tray-arrow (7px) + wrapper pt-1.5 (6px) + bottom p-6 (24px)
const TRAY_SETTINGS_DEBOUNCE_MS = 2000;
const TRAY_PROBE_DEBOUNCE_MS = 500;

type PluginState = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
  lastManualRefreshAt: number | null
}

function App() {
  const [activeView, setActiveView] = useState<ActiveView>("home");
  const containerRef = useRef<HTMLDivElement>(null);
  const [pluginStates, setPluginStates] = useState<Record<string, PluginState>>({})
  const [pluginsMeta, setPluginsMeta] = useState<PluginMeta[]>([])
  const [pluginSettings, setPluginSettings] = useState<PluginSettings | null>(null)
  const [autoUpdateInterval, setAutoUpdateInterval] = useState<AutoUpdateIntervalMinutes>(
    DEFAULT_AUTO_UPDATE_INTERVAL
  )
  const [autoUpdateNextAt, setAutoUpdateNextAt] = useState<number | null>(null)
  const [autoUpdateResetToken, setAutoUpdateResetToken] = useState(0)
  const [themeMode, setThemeMode] = useState<ThemeMode>(DEFAULT_THEME_MODE)
  const [maxPanelHeightPx, setMaxPanelHeightPx] = useState<number | null>(null)
  const maxPanelHeightPxRef = useRef<number | null>(null)
  const [appVersion, setAppVersion] = useState("...")

  const { updateStatus, triggerInstall, checkForUpdates } = useAppUpdate()
  const [showAbout, setShowAbout] = useState(false)

  const trayRef = useRef<TrayIcon | null>(null)
  const trayGaugeIconPathRef = useRef<string | null>(null)
  const trayUpdateTimerRef = useRef<number | null>(null)
  const trayUpdatePendingRef = useRef(false)
  const [trayReady, setTrayReady] = useState(false)

  // Store state in refs so scheduleTrayIconUpdate can read current values without recreating the callback
  const pluginsMetaRef = useRef(pluginsMeta)
  const pluginSettingsRef = useRef(pluginSettings)
  const pluginStatesRef = useRef(pluginStates)
  useEffect(() => { pluginsMetaRef.current = pluginsMeta }, [pluginsMeta])
  useEffect(() => { pluginSettingsRef.current = pluginSettings }, [pluginSettings])
  useEffect(() => { pluginStatesRef.current = pluginStates }, [pluginStates])

  // Fetch app version on mount
  useEffect(() => {
    getVersion().then(setAppVersion)
  }, [])

  // Stable callback that reads from refs - never recreated, so debounce works correctly
  const scheduleTrayIconUpdate = useCallback((_reason: "probe" | "settings" | "init", delayMs = 0) => {
    if (trayUpdateTimerRef.current !== null) {
      window.clearTimeout(trayUpdateTimerRef.current)
      trayUpdateTimerRef.current = null
    }

    trayUpdateTimerRef.current = window.setTimeout(() => {
      trayUpdateTimerRef.current = null
      if (trayUpdatePendingRef.current) return
      trayUpdatePendingRef.current = true

      const tray = trayRef.current
      if (!tray) {
        trayUpdatePendingRef.current = false
        return
      }

      const bars = getTrayPrimaryBars({
        pluginsMeta: pluginsMetaRef.current,
        pluginSettings: pluginSettingsRef.current,
        pluginStates: pluginStatesRef.current,
        maxBars: 4,
      })

      // 0 bars: revert to the packaged gauge tray icon.
      if (bars.length === 0) {
        const gaugePath = trayGaugeIconPathRef.current
        if (gaugePath) {
          Promise.all([
            tray.setIcon(gaugePath),
            tray.setIconAsTemplate(true),
          ])
            .catch((e) => {
              console.error("Failed to restore tray gauge icon:", e)
            })
            .finally(() => {
              trayUpdatePendingRef.current = false
            })
        } else {
          trayUpdatePendingRef.current = false
        }
        return
      }

      const sizePx = getTrayIconSizePx(window.devicePixelRatio)

      renderTrayBarsIcon({ bars, sizePx })
        .then(async (img) => {
          await tray.setIcon(img)
          await tray.setIconAsTemplate(true)
        })
        .catch((e) => {
          console.error("Failed to update tray icon:", e)
        })
        .finally(() => {
          trayUpdatePendingRef.current = false
        })
    }, delayMs)
  }, [])

  // Initialize tray handle once (separate from tray updates)
  const trayInitializedRef = useRef(false)
  useEffect(() => {
    if (trayInitializedRef.current) return
    let cancelled = false
    ;(async () => {
      try {
        const tray = await TrayIcon.getById("tray")
        if (cancelled) return
        trayRef.current = tray
        trayInitializedRef.current = true
        setTrayReady(true)
        try {
          trayGaugeIconPathRef.current = await resolveResource("icons/tray-icon.png")
        } catch (e) {
          console.error("Failed to resolve tray gauge icon resource:", e)
        }
      } catch (e) {
        console.error("Failed to load tray icon handle:", e)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [])

  // Trigger tray update once tray + plugin metadata/settings are available.
  // This prevents missing the first paint if probe results arrive before the tray handle resolves.
  useEffect(() => {
    if (!trayReady) return
    if (!pluginSettings) return
    if (pluginsMeta.length === 0) return
    scheduleTrayIconUpdate("init", 0)
  }, [pluginsMeta.length, pluginSettings, scheduleTrayIconUpdate, trayReady])


  const displayPlugins = useMemo(() => {
    if (!pluginSettings) return []
    const disabledSet = new Set(pluginSettings.disabled)
    const metaById = new Map(pluginsMeta.map((plugin) => [plugin.id, plugin]))
    return pluginSettings.order
      .filter((id) => !disabledSet.has(id))
      .map((id) => {
        const meta = metaById.get(id)
        if (!meta) return null
        const state = pluginStates[id] ?? { data: null, loading: false, error: null, lastManualRefreshAt: null }
        return { meta, ...state }
      })
      .filter((plugin): plugin is { meta: PluginMeta } & PluginState => Boolean(plugin))
  }, [pluginSettings, pluginStates, pluginsMeta])

  // Derive enabled plugin list for nav icons
  const navPlugins = useMemo(() => {
    if (!pluginSettings) return []
    const disabledSet = new Set(pluginSettings.disabled)
    const metaById = new Map(pluginsMeta.map((p) => [p.id, p]))
    return pluginSettings.order
      .filter((id) => !disabledSet.has(id))
      .map((id) => metaById.get(id))
      .filter((p): p is PluginMeta => Boolean(p))
      .map((p) => ({ id: p.id, name: p.name, iconUrl: p.iconUrl, brandColor: p.brandColor }))
  }, [pluginSettings, pluginsMeta])

  // If active view is a plugin that got disabled, switch to home
  useEffect(() => {
    if (activeView === "home" || activeView === "settings") return
    const isStillEnabled = navPlugins.some((p) => p.id === activeView)
    if (!isStillEnabled) {
      setActiveView("home")
    }
  }, [activeView, navPlugins])

  // Get the selected plugin for detail view
  const selectedPlugin = useMemo(() => {
    if (activeView === "home" || activeView === "settings") return null
    return displayPlugins.find((p) => p.meta.id === activeView) ?? null
  }, [activeView, displayPlugins])


  // Initialize panel on mount
  useEffect(() => {
    invoke("init_panel").catch(console.error);
  }, []);

  // Listen for tray menu events
  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false
    const unlisteners: (() => void)[] = []

    async function setup() {
      const u1 = await listen<string>("tray:navigate", (event) => {
        setActiveView(event.payload as ActiveView)
      })
      if (cancelled) { u1(); return }
      unlisteners.push(u1)

      const u2 = await listen("tray:show-about", () => {
        setShowAbout(true)
      })
      if (cancelled) { u2(); return }
      unlisteners.push(u2)
    }
    void setup()

    return () => {
      cancelled = true
      for (const fn of unlisteners) fn()
    }
  }, [])

  // Auto-resize window to fit content using ResizeObserver
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const resizeWindow = async () => {
      const factor = window.devicePixelRatio;

      const width = Math.ceil(PANEL_WIDTH * factor);
      const desiredHeightLogical = Math.max(1, container.scrollHeight);

      let maxHeightPhysical: number | null = null;
      let maxHeightLogical: number | null = null;
      try {
        const monitor = await currentMonitor();
        if (monitor) {
          maxHeightPhysical = Math.floor(monitor.size.height * MAX_HEIGHT_FRACTION_OF_MONITOR);
          maxHeightLogical = Math.floor(maxHeightPhysical / factor);
        }
      } catch {
        // fall through to fallback
      }

      if (maxHeightLogical === null) {
        const screenAvailHeight = Number(window.screen?.availHeight) || MAX_HEIGHT_FALLBACK_PX;
        maxHeightLogical = Math.floor(screenAvailHeight * MAX_HEIGHT_FRACTION_OF_MONITOR);
        maxHeightPhysical = Math.floor(maxHeightLogical * factor);
      }

      if (maxPanelHeightPxRef.current !== maxHeightLogical) {
        maxPanelHeightPxRef.current = maxHeightLogical;
        setMaxPanelHeightPx(maxHeightLogical);
      }

      const desiredHeightPhysical = Math.ceil(desiredHeightLogical * factor);
      const height = Math.ceil(Math.min(desiredHeightPhysical, maxHeightPhysical!));

      try {
        const currentWindow = getCurrentWindow();
        await currentWindow.setSize(new PhysicalSize(width, height));
      } catch (e) {
        console.error("Failed to resize window:", e);
      }
    };

    // Initial resize
    resizeWindow();

    // Observe size changes
    const observer = new ResizeObserver(() => {
      resizeWindow();
    });
    observer.observe(container);

    return () => observer.disconnect();
  }, [activeView, displayPlugins]);

  const getErrorMessage = useCallback((output: PluginOutput) => {
    if (output.lines.length !== 1) return null
    const line = output.lines[0]
    if (line.type === "badge" && line.label === "Error") {
      return line.text || "Couldn't update data. Try again?"
    }
    return null
  }, [])

  const setLoadingForPlugins = useCallback((ids: string[]) => {
    setPluginStates((prev) => {
      const next = { ...prev }
      for (const id of ids) {
        const existing = prev[id]
        next[id] = { data: null, loading: true, error: null, lastManualRefreshAt: existing?.lastManualRefreshAt ?? null }
      }
      return next
    })
  }, [])

  const setErrorForPlugins = useCallback((ids: string[], error: string) => {
    setPluginStates((prev) => {
      const next = { ...prev }
      for (const id of ids) {
        const existing = prev[id]
        next[id] = { data: null, loading: false, error, lastManualRefreshAt: existing?.lastManualRefreshAt ?? null }
      }
      return next
    })
  }, [])

  // Track which plugin IDs are being manually refreshed (vs initial load / enable toggle)
  const manualRefreshIdsRef = useRef<Set<string>>(new Set())

  const handleProbeResult = useCallback(
    (output: PluginOutput) => {
      const errorMessage = getErrorMessage(output)
      const isManual = manualRefreshIdsRef.current.has(output.providerId)
      if (isManual) {
        manualRefreshIdsRef.current.delete(output.providerId)
      }
      setPluginStates((prev) => ({
        ...prev,
        [output.providerId]: {
          data: errorMessage ? null : output,
          loading: false,
          error: errorMessage,
          // Only set cooldown timestamp for successful manual refreshes
          lastManualRefreshAt: (!errorMessage && isManual)
            ? Date.now()
            : (prev[output.providerId]?.lastManualRefreshAt ?? null),
        },
      }))

      // Regenerate tray icon on every probe result (debounced to avoid churn).
      scheduleTrayIconUpdate("probe", TRAY_PROBE_DEBOUNCE_MS)
    },
    [getErrorMessage, scheduleTrayIconUpdate]
  )

  const handleBatchComplete = useCallback(() => {}, [])

  const { startBatch } = useProbeEvents({
    onResult: handleProbeResult,
    onBatchComplete: handleBatchComplete,
  })

  useEffect(() => {
    let isMounted = true

    const loadSettings = async () => {
      try {
        const availablePlugins = await invoke<PluginMeta[]>("list_plugins")
        if (!isMounted) return
        setPluginsMeta(availablePlugins)

        const storedSettings = await loadPluginSettings()
        const normalized = normalizePluginSettings(
          storedSettings,
          availablePlugins
        )

        if (!arePluginSettingsEqual(storedSettings, normalized)) {
          await savePluginSettings(normalized)
        }

        let storedInterval = DEFAULT_AUTO_UPDATE_INTERVAL
        try {
          storedInterval = await loadAutoUpdateInterval()
        } catch (error) {
          console.error("Failed to load auto-update interval:", error)
        }

        let storedThemeMode = DEFAULT_THEME_MODE
        try {
          storedThemeMode = await loadThemeMode()
        } catch (error) {
          console.error("Failed to load theme mode:", error)
        }

        if (isMounted) {
          setPluginSettings(normalized)
          setAutoUpdateInterval(storedInterval)
          setThemeMode(storedThemeMode)
          const enabledIds = getEnabledPluginIds(normalized)
          setLoadingForPlugins(enabledIds)
          try {
            await startBatch(enabledIds)
          } catch (error) {
            console.error("Failed to start probe batch:", error)
            if (isMounted) {
              setErrorForPlugins(enabledIds, "Failed to start probe")
            }
          }
        }
      } catch (e) {
        console.error("Failed to load plugin settings:", e)
      }
    }

    loadSettings()

    return () => {
      isMounted = false
    }
  }, [setLoadingForPlugins, setErrorForPlugins, startBatch])

  useEffect(() => {
    if (!pluginSettings) {
      setAutoUpdateNextAt(null)
      return
    }
    const enabledIds = getEnabledPluginIds(pluginSettings)
    if (enabledIds.length === 0) {
      setAutoUpdateNextAt(null)
      return
    }
    const intervalMs = autoUpdateInterval * 60_000
    const scheduleNext = () => setAutoUpdateNextAt(Date.now() + intervalMs)
    scheduleNext()
    const interval = setInterval(() => {
      setLoadingForPlugins(enabledIds)
      startBatch(enabledIds).catch((error) => {
        console.error("Failed to start auto-update batch:", error)
        setErrorForPlugins(enabledIds, "Failed to start probe")
      })
      scheduleNext()
    }, intervalMs)
    return () => clearInterval(interval)
  }, [
    autoUpdateInterval,
    autoUpdateResetToken,
    pluginSettings,
    setLoadingForPlugins,
    setErrorForPlugins,
    startBatch,
  ])

  // Apply theme mode to document
  useEffect(() => {
    const root = document.documentElement
    const apply = (dark: boolean) => {
      root.classList.toggle("dark", dark)
    }

    if (themeMode === "light") {
      apply(false)
      return
    }
    if (themeMode === "dark") {
      apply(true)
      return
    }

    // "system" — follow OS preference
    const mq = window.matchMedia("(prefers-color-scheme: dark)")
    apply(mq.matches)
    const handler = (e: MediaQueryListEvent) => apply(e.matches)
    mq.addEventListener("change", handler)
    return () => mq.removeEventListener("change", handler)
  }, [themeMode])

  const resetAutoUpdateSchedule = useCallback(() => {
    if (!pluginSettings) return
    const enabledIds = getEnabledPluginIds(pluginSettings)
    // Defensive: retry only possible for enabled plugins, so this branch is unreachable in normal use
    /* v8 ignore start */
    if (enabledIds.length === 0) {
      setAutoUpdateNextAt(null)
      return
    }
    /* v8 ignore stop */
    setAutoUpdateNextAt(Date.now() + autoUpdateInterval * 60_000)
    setAutoUpdateResetToken((value) => value + 1)
  }, [autoUpdateInterval, pluginSettings])

  const handleRetryPlugin = useCallback(
    (id: string) => {
      resetAutoUpdateSchedule()
      // Mark as manual refresh
      manualRefreshIdsRef.current.add(id)
      setLoadingForPlugins([id])
      startBatch([id]).catch((error) => {
        console.error("Failed to retry plugin:", error)
        setErrorForPlugins([id], "Failed to start probe")
      })
    },
    [resetAutoUpdateSchedule, setLoadingForPlugins, setErrorForPlugins, startBatch]
  )

  const handleThemeModeChange = useCallback((mode: ThemeMode) => {
    setThemeMode(mode)
    void saveThemeMode(mode).catch((error) => {
      console.error("Failed to save theme mode:", error)
    })
  }, [])

  const handleAutoUpdateIntervalChange = useCallback((value: AutoUpdateIntervalMinutes) => {
    setAutoUpdateInterval(value)
    if (pluginSettings) {
      const enabledIds = getEnabledPluginIds(pluginSettings)
      if (enabledIds.length > 0) {
        setAutoUpdateNextAt(Date.now() + value * 60_000)
      } else {
        setAutoUpdateNextAt(null)
      }
    }
    void saveAutoUpdateInterval(value).catch((error) => {
      console.error("Failed to save auto-update interval:", error)
    })
  }, [pluginSettings])

  const settingsPlugins = useMemo(() => {
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
      .filter((plugin): plugin is { id: string; name: string; enabled: boolean } =>
        Boolean(plugin)
      )
  }, [pluginSettings, pluginsMeta])

  const handleReorder = useCallback(
    (orderedIds: string[]) => {
      if (!pluginSettings) return
      const nextSettings: PluginSettings = {
        ...pluginSettings,
        order: orderedIds,
      }
      setPluginSettings(nextSettings)
      scheduleTrayIconUpdate("settings", TRAY_SETTINGS_DEBOUNCE_MS)
      void savePluginSettings(nextSettings).catch((error) => {
        console.error("Failed to save plugin order:", error)
      })
    },
    [pluginSettings, scheduleTrayIconUpdate]
  )

  const handleToggle = useCallback(
    (id: string) => {
      if (!pluginSettings) return
      const wasDisabled = pluginSettings.disabled.includes(id)
      const disabled = new Set(pluginSettings.disabled)

      if (wasDisabled) {
        disabled.delete(id)
        setLoadingForPlugins([id])
        startBatch([id]).catch((error) => {
          console.error("Failed to start probe for enabled plugin:", error)
          setErrorForPlugins([id], "Failed to start probe")
        })
      } else {
        disabled.add(id)
        // No probe needed for disable
      }

      const nextSettings: PluginSettings = {
        ...pluginSettings,
        disabled: Array.from(disabled),
      }
      setPluginSettings(nextSettings)
      scheduleTrayIconUpdate("settings", TRAY_SETTINGS_DEBOUNCE_MS)
      void savePluginSettings(nextSettings).catch((error) => {
        console.error("Failed to save plugin toggle:", error)
      })
    },
    [pluginSettings, setLoadingForPlugins, setErrorForPlugins, startBatch, scheduleTrayIconUpdate]
  )

  // Render content based on active view
  const renderContent = () => {
    if (activeView === "home") {
      return (
        <OverviewPage
          plugins={displayPlugins}
          onRetryPlugin={handleRetryPlugin}
        />
      )
    }
    if (activeView === "settings") {
      return (
        <SettingsPage
          plugins={settingsPlugins}
          onReorder={handleReorder}
          onToggle={handleToggle}
          autoUpdateInterval={autoUpdateInterval}
          onAutoUpdateIntervalChange={handleAutoUpdateIntervalChange}
          themeMode={themeMode}
          onThemeModeChange={handleThemeModeChange}
          updateStatus={updateStatus}
          onCheckForUpdates={checkForUpdates}
        />
      )
    }
    // Provider detail view
    const handleRetry = selectedPlugin
      ? () => handleRetryPlugin(selectedPlugin.meta.id)
      : /* v8 ignore next */ undefined
    return <ProviderDetailPage plugin={selectedPlugin} onRetry={handleRetry} />
  }

  return (
    <div ref={containerRef} className="flex flex-col items-center p-6 pt-1.5 bg-transparent">
      <div className="tray-arrow" />
      <div
        className="bg-card rounded-xl overflow-hidden select-none w-full border shadow-lg"
        style={maxPanelHeightPx ? { maxHeight: `${maxPanelHeightPx - ARROW_OVERHEAD_PX}px` } : undefined}
      >
        <div className="flex h-full min-h-0 flex-row">
          <SideNav
            activeView={activeView}
            onViewChange={setActiveView}
            plugins={navPlugins}
          />
          <div className="flex-1 flex flex-col px-3 pt-2 pb-1.5 min-w-0">
            <div className="flex-1 min-h-0 overflow-y-auto">
              {renderContent()}
            </div>
            <PanelFooter
              version={appVersion}
              autoUpdateNextAt={autoUpdateNextAt}
              updateStatus={updateStatus}
              onUpdateInstall={triggerInstall}
              showAbout={showAbout}
              onShowAbout={() => setShowAbout(true)}
              onCloseAbout={() => setShowAbout(false)}
            />
          </div>
        </div>
      </div>
    </div>
  );
}

export default App;
