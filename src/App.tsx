import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { getCurrentWindow, PhysicalSize, PhysicalPosition, currentMonitor } from "@tauri-apps/api/window"
import { getVersion } from "@tauri-apps/api/app"
import { TrayIcon } from "@tauri-apps/api/tray"
import { resolveResource } from "@tauri-apps/api/path"
import { platform } from "@tauri-apps/plugin-os"
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
  DEFAULT_DISPLAY_MODE,
  DEFAULT_TRAY_ICON_STYLE,
  DEFAULT_TRAY_SHOW_PERCENTAGE,
  DEFAULT_THEME_MODE,
  getEnabledPluginIds,
  isTrayPercentageMandatory,
  loadAutoUpdateInterval,
  loadDisplayMode,
  loadPluginSettings,
  loadTrayShowPercentage,
  loadTrayIconStyle,
  loadThemeMode,
  normalizePluginSettings,
  saveAutoUpdateInterval,
  saveDisplayMode,
  savePluginSettings,
  saveTrayShowPercentage,
  saveTrayIconStyle,
  saveThemeMode,
  type AutoUpdateIntervalMinutes,
  type DisplayMode,
  type PluginSettings,
  type TrayIconStyle,
  type ThemeMode,
} from "@/lib/settings"

const PANEL_WIDTH = 400;
const MAX_HEIGHT_FALLBACK_PX = 600;
const MAX_HEIGHT_FRACTION_OF_MONITOR = 0.8;
const ARROW_OVERHEAD_PX = 32; // Arrow (~16px) + container padding (16px)
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
  const scrollRef = useRef<HTMLDivElement>(null);
  const [canScrollDown, setCanScrollDown] = useState(false);
  const [pluginStates, setPluginStates] = useState<Record<string, PluginState>>({})
  const [pluginsMeta, setPluginsMeta] = useState<PluginMeta[]>([])
  const [pluginSettings, setPluginSettings] = useState<PluginSettings | null>(null)
  const [autoUpdateInterval, setAutoUpdateInterval] = useState<AutoUpdateIntervalMinutes>(
    DEFAULT_AUTO_UPDATE_INTERVAL
  )
  const [autoUpdateNextAt, setAutoUpdateNextAt] = useState<number | null>(null)
  const [autoUpdateResetToken, setAutoUpdateResetToken] = useState(0)
  const [themeMode, setThemeMode] = useState<ThemeMode>(DEFAULT_THEME_MODE)
  const [displayMode, setDisplayMode] = useState<DisplayMode>(DEFAULT_DISPLAY_MODE)
  const [trayIconStyle, setTrayIconStyle] = useState<TrayIconStyle>(DEFAULT_TRAY_ICON_STYLE)
  const [isWindows, setIsWindows] = useState(false)
  const [trayShowPercentage, setTrayShowPercentage] = useState(DEFAULT_TRAY_SHOW_PERCENTAGE)
  const [maxPanelHeightPx, setMaxPanelHeightPx] = useState<number | null>(null)
  const maxPanelHeightPxRef = useRef<number | null>(null)
  const [appVersion, setAppVersion] = useState("...")
  // Track taskbar position for anchor-aware resizing (Windows)
  type TaskbarPosition = "top" | "bottom" | "left" | "right" | null
  const [taskbarPosition, setTaskbarPosition] = useState<TaskbarPosition>(null)
  // Track last window height to calculate delta for repositioning
  const lastWindowHeightRef = useRef<number | null>(null)
  // Arrow offset from left edge (in logical px) - where tray icon center is relative to window
  const [arrowOffset, setArrowOffset] = useState<number | null>(null)

  const { updateStatus, triggerInstall } = useAppUpdate()
  const [showAbout, setShowAbout] = useState(false)

  // Tray icon handle for frontend updates
  const trayRef = useRef<TrayIcon | null>(null)
  const trayUpdateTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Store state in refs so scheduleTrayIconUpdate can read current values without recreating the callback
  const pluginsMetaRef = useRef(pluginsMeta)
  const pluginSettingsRef = useRef(pluginSettings)
  const pluginStatesRef = useRef(pluginStates)
  const displayModeRef = useRef(displayMode)
  const trayIconStyleRef = useRef(trayIconStyle)
  const trayShowPercentageRef = useRef(trayShowPercentage)
  useEffect(() => { pluginsMetaRef.current = pluginsMeta }, [pluginsMeta])
  useEffect(() => { pluginSettingsRef.current = pluginSettings }, [pluginSettings])
  useEffect(() => { pluginStatesRef.current = pluginStates }, [pluginStates])
  useEffect(() => { displayModeRef.current = displayMode }, [displayMode])
  useEffect(() => { trayIconStyleRef.current = trayIconStyle }, [trayIconStyle])
  useEffect(() => { trayShowPercentageRef.current = trayShowPercentage }, [trayShowPercentage])

  // Fetch app version and detect platform on mount
  useEffect(() => {
    getVersion().then(setAppVersion)
    // Detect if Windows for arrow positioning
    try {
      const p = platform()
      setIsWindows(p === 'windows')
    } catch {
      setIsWindows(false)
    }
  }, [])

  const [isTrayReady, setIsTrayReady] = useState(false)
  const scheduleTrayIconUpdate = useCallback((reason: "probe" | "settings" | "init", delayMs = 0) => {
    if (trayUpdateTimeoutRef.current !== null) {
      clearTimeout(trayUpdateTimeoutRef.current)
    }

    trayUpdateTimeoutRef.current = setTimeout(async () => {
      trayUpdateTimeoutRef.current = null
      const currentSettings = pluginSettingsRef.current
      const currentMeta = pluginsMetaRef.current
      if (!currentSettings || currentMeta.length === 0) return

      const style = trayIconStyleRef.current
      const maxBars = style === "bars" ? 4 : 1
      const bars = getTrayPrimaryBars({
        pluginsMeta: currentMeta,
        pluginSettings: currentSettings,
        pluginStates: pluginStatesRef.current,
        displayMode: displayModeRef.current,
        maxBars,
      })
      if (bars.length === 0) return
      const shouldShowPercentage = isTrayPercentageMandatory(style)
        ? true
        : trayShowPercentageRef.current
      const primaryFraction = bars[0]?.fraction
      const percentText =
        shouldShowPercentage && typeof primaryFraction === "number"
          ? `${Math.round(primaryFraction * 100)}%`
          : undefined
      const providerIconUrl =
        style === "provider"
          ? currentMeta.find((plugin) => plugin.id === bars[0]?.id)?.iconUrl
          : undefined
      const dpr = typeof window === "undefined" ? 1 : window.devicePixelRatio || 1
      const sizePx = getTrayIconSizePx(dpr)

      try {
        const image = await renderTrayBarsIcon({
          bars,
          sizePx,
          style,
          percentText,
          providerIconUrl,
        })
        let tray = trayRef.current
        if (!tray) {
          tray = await TrayIcon.getById("tray").catch(() => null)
          if (tray) trayRef.current = tray
        }
        if (tray) {
          await tray.setIcon(image)
        }
      } catch (error) {
        console.error(`Failed to update tray icon (${reason}):`, error)
      }
    }, delayMs)
  }, [])

  useEffect(() => {
    if (!isTrayReady) return
    if (!pluginSettings || pluginsMeta.length === 0) return
    scheduleTrayIconUpdate("init", 0)
  }, [isTrayReady, pluginSettings, pluginsMeta, scheduleTrayIconUpdate])

  useEffect(() => {
    let cancelled = false
    resolveResource("icons/tray-icon.png").catch((error) => {
      if (cancelled) return
      console.error("Failed to resolve tray icon resource:", error)
    })
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    return () => {
      if (trayUpdateTimeoutRef.current !== null) {
        clearTimeout(trayUpdateTimeoutRef.current)
      }
    }
  }, [])

  // Initialize tray handle once
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
        setIsTrayReady(true)
      } catch (e) {
        console.error("Failed to load tray icon handle:", e)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [])


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

  // Hide panel on Escape key (unless about dialog is open - it handles its own Escape)
  useEffect(() => {
    if (!isTauri()) return
    if (showAbout) return // Let dialog handle its own Escape

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        invoke("hide_panel")
      }
    }
    document.addEventListener("keydown", handleKeyDown)
    return () => document.removeEventListener("keydown", handleKeyDown)
  }, [showAbout])

  // Listen for tray menu events
  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false
    const unlisteners: (() => void)[] = []

    async function setup() {
      const currentWindow = getCurrentWindow()
      
      const u1 = await listen<string>("tray:navigate", async (event) => {
        // Capture current height before navigation so we can calculate delta
        try {
          const size = await currentWindow.outerSize()
          lastWindowHeightRef.current = size.height
        } catch {
          lastWindowHeightRef.current = null
        }
        setActiveView(event.payload as ActiveView)
      })
      if (cancelled) { u1(); return }
      unlisteners.push(u1)

      const u2 = await listen("tray:show-about", () => {
        setShowAbout(true)
      })
      if (cancelled) { u2(); return }
      unlisteners.push(u2)

      // Listen for window focus events to capture current height as baseline
      // This ensures we can calculate proper deltas for anchor-aware resizing
      const u3 = await currentWindow.onFocusChanged(async ({ payload: focused }) => {
        if (focused) {
          // Window just gained focus - capture current height as baseline for delta calculation
          try {
            const size = await currentWindow.outerSize()
            lastWindowHeightRef.current = size.height
            console.log('[FOCUS] Window focused, captured baseline height:', size.height)

            // Fetch latest positioning info (in case event was missed)
            const pos = await invoke<string | null>('get_taskbar_position');
            if (pos) setTaskbarPosition(pos as TaskbarPosition);
            
            const offset = await invoke<number | null>('get_arrow_offset');
            if (offset !== null) setArrowOffset(offset);
          } catch {
            // Fallback: null will cause first resize to just set size without repositioning
            lastWindowHeightRef.current = null
            console.log('[FOCUS] Window focused, failed to capture height')
          }
        }
      })
      if (cancelled) { u3(); return }
      unlisteners.push(u3)

      // Listen for window positioning events to align arrow with tray icon
      const u4 = await listen<{ arrowOffset: number; taskbarPosition: string }>("window:positioned", (event) => {
        setArrowOffset(event.payload.arrowOffset)
        setTaskbarPosition(event.payload.taskbarPosition as TaskbarPosition)
        console.log('[POSITIONED] Arrow offset:', event.payload.arrowOffset, 'Taskbar:', event.payload.taskbarPosition)
      })
      if (cancelled) { u4(); return }
      unlisteners.push(u4)
    }
    void setup()

    return () => {
      cancelled = true
      for (const fn of unlisteners) fn()
    }
  }, [])

  // Auto-resize window to fit content using ResizeObserver
  // CRITICAL: Anchor-aware resizing - keep the edge closest to taskbar fixed
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    let debounceTimer: ReturnType<typeof setTimeout> | null = null;
    let isResizing = false;

    const resizeWindow = async () => {
      // Prevent concurrent resize operations
      if (isResizing) return;
      isResizing = true;

      try {
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
        const newHeight = Math.ceil(Math.min(desiredHeightPhysical, maxHeightPhysical!));
        const previousHeight = lastWindowHeightRef.current;

        const currentWindow = getCurrentWindow();

        // Fetch current taskbar position from backend (Windows stores this on tray click)
        let currentTaskbarPos: TaskbarPosition = null;
        try {
          currentTaskbarPos = await invoke<TaskbarPosition>("get_taskbar_position");
          setTaskbarPosition(currentTaskbarPos);
        } catch {
          // Fallback: not available or macOS
        }

        // On Windows with bottom/right taskbar, we need to reposition when height changes
        // to keep the bottom/right edge anchored
        if (previousHeight !== null && previousHeight !== newHeight && currentTaskbarPos) {
          const heightDelta = newHeight - previousHeight;

          // Get current window position
          const pos = await currentWindow.outerPosition();

          if (currentTaskbarPos === "bottom") {
            // Bottom taskbar: keep bottom edge fixed → move window UP when growing
            const newY = pos.y - heightDelta;
            await currentWindow.setPosition(new PhysicalPosition(pos.x, newY));
          }
          // Top/Left taskbar: default behavior (top-left anchored)
          // Right taskbar: no vertical adjustment needed for height changes
        }

        await currentWindow.setSize(new PhysicalSize(width, newHeight));
        lastWindowHeightRef.current = newHeight;
      } catch (e) {
        console.error("Failed to resize window:", e);
      } finally {
        isResizing = false;
      }
    };

    // Debounced resize to prevent rapid consecutive calls
    const debouncedResize = () => {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(resizeWindow, 16); // ~1 frame at 60fps
    };

    // Initial resize (no debounce)
    resizeWindow();

    // Observe size changes with debouncing
    const observer = new ResizeObserver(debouncedResize);
    observer.observe(container);

    return () => {
      if (debounceTimer) clearTimeout(debounceTimer);
      observer.disconnect();
    };
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
    const prev = pluginStatesRef.current
    const next = { ...prev }
    for (const id of ids) {
      const existing = prev[id]
      next[id] = { data: null, loading: true, error: null, lastManualRefreshAt: existing?.lastManualRefreshAt ?? null }
    }
    pluginStatesRef.current = next
    setPluginStates(next)
  }, [])

  const setErrorForPlugins = useCallback((ids: string[], error: string) => {
    const prev = pluginStatesRef.current
    const next = { ...prev }
    for (const id of ids) {
      const existing = prev[id]
      next[id] = { data: null, loading: false, error, lastManualRefreshAt: existing?.lastManualRefreshAt ?? null }
    }
    pluginStatesRef.current = next
    setPluginStates(next)
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
      const prev = pluginStatesRef.current
      const next = {
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
      }
      pluginStatesRef.current = next
      setPluginStates(next)

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
        pluginsMetaRef.current = availablePlugins

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

        let storedDisplayMode = DEFAULT_DISPLAY_MODE
        try {
          storedDisplayMode = await loadDisplayMode()
        } catch (error) {
          console.error("Failed to load display mode:", error)
        }

        let storedTrayIconStyle = DEFAULT_TRAY_ICON_STYLE
        try {
          storedTrayIconStyle = await loadTrayIconStyle()
        } catch (error) {
          console.error("Failed to load tray icon style:", error)
        }

        let storedTrayShowPercentage = DEFAULT_TRAY_SHOW_PERCENTAGE
        try {
          storedTrayShowPercentage = await loadTrayShowPercentage()
        } catch (error) {
          console.error("Failed to load tray show percentage:", error)
        }

        const normalizedTrayShowPercentage = isTrayPercentageMandatory(storedTrayIconStyle)
          ? true
          : storedTrayShowPercentage

        if (isMounted) {
          setPluginSettings(normalized)
          pluginSettingsRef.current = normalized
          setAutoUpdateInterval(storedInterval)
          setThemeMode(storedThemeMode)
          setDisplayMode(storedDisplayMode)
          displayModeRef.current = storedDisplayMode
          setTrayIconStyle(storedTrayIconStyle)
          trayIconStyleRef.current = storedTrayIconStyle
          setTrayShowPercentage(normalizedTrayShowPercentage)
          trayShowPercentageRef.current = normalizedTrayShowPercentage
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

        if (
          isTrayPercentageMandatory(storedTrayIconStyle) &&
          storedTrayShowPercentage !== true
        ) {
          void saveTrayShowPercentage(true).catch((error) => {
            console.error("Failed to save tray show percentage:", error)
          })
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

  const handleDisplayModeChange = useCallback((mode: DisplayMode) => {
    setDisplayMode(mode)
    // Display mode is a direct user-facing toggle; update tray immediately.
    scheduleTrayIconUpdate("settings", 0)
    void saveDisplayMode(mode).catch((error) => {
      console.error("Failed to save display mode:", error)
    })
  }, [scheduleTrayIconUpdate])

  const handleTrayIconStyleChange = useCallback((style: TrayIconStyle) => {
    const mandatory = isTrayPercentageMandatory(style)
    if (mandatory && trayShowPercentageRef.current !== true) {
      trayShowPercentageRef.current = true
      setTrayShowPercentage(true)
      void saveTrayShowPercentage(true).catch((error) => {
        console.error("Failed to save tray show percentage:", error)
      })
    }

    trayIconStyleRef.current = style
    setTrayIconStyle(style)
    // Tray icon style is a direct user-facing toggle; update tray immediately.
    scheduleTrayIconUpdate("settings", 0)
    void saveTrayIconStyle(style).catch((error) => {
      console.error("Failed to save tray icon style:", error)
    })
  }, [scheduleTrayIconUpdate])

  const handleTrayShowPercentageChange = useCallback((value: boolean) => {
    trayShowPercentageRef.current = value
    setTrayShowPercentage(value)
    // Tray icon text visibility is a direct user-facing toggle; update tray immediately.
    scheduleTrayIconUpdate("settings", 0)
    void saveTrayShowPercentage(value).catch((error) => {
      console.error("Failed to save tray show percentage:", error)
    })
  }, [scheduleTrayIconUpdate])

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

  // Detect whether the scroll area has overflow below
  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    const check = () => {
      setCanScrollDown(el.scrollHeight - el.scrollTop - el.clientHeight > 1)
    }
    check()
    el.addEventListener("scroll", check, { passive: true })
    const ro = new ResizeObserver(check)
    ro.observe(el)
    // Re-check when child content changes (async data loads)
    const mo = new MutationObserver(check)
    mo.observe(el, { childList: true, subtree: true })
    return () => {
      el.removeEventListener("scroll", check)
      ro.disconnect()
      mo.disconnect()
    }
  }, [activeView])

  // Render content based on active view
  const renderContent = () => {
    if (activeView === "home") {
      return (
        <OverviewPage
          plugins={displayPlugins}
          onRetryPlugin={handleRetryPlugin}
          displayMode={displayMode}
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
          displayMode={displayMode}
          onDisplayModeChange={handleDisplayModeChange}
          trayIconStyle={trayIconStyle}
          onTrayIconStyleChange={handleTrayIconStyleChange}
          trayShowPercentage={trayShowPercentage}
          onTrayShowPercentageChange={handleTrayShowPercentageChange}
          providerIconUrl={navPlugins[0]?.iconUrl}
        />
      )
    }
    // Provider detail view
    const handleRetry = selectedPlugin
      ? () => handleRetryPlugin(selectedPlugin.meta.id)
      : /* v8 ignore next */ undefined
    return (
      <ProviderDetailPage
        plugin={selectedPlugin}
        onRetry={handleRetry}
        displayMode={displayMode}
      />
    )
  }

  const isSideTaskbar = taskbarPosition === "left" || taskbarPosition === "right"
  const isTopTaskbar = taskbarPosition === "top"
  const isLeftTaskbar = taskbarPosition === "left"
  const isRightTaskbar = taskbarPosition === "right"

  // Padding for shadow: needs ~16px to not clip the box-shadow
  // Arrow side gets 8px (arrow is 16px), opposite side gets 16px for shadow
  const containerClasses = isWindows
    ? isSideTaskbar
      ? "flex flex-row items-center w-full py-4 px-2 bg-transparent"
      : isTopTaskbar
        ? "flex flex-col items-center justify-start w-full px-4 pt-2 pb-4 bg-transparent"
        : "flex flex-col items-center justify-end w-full px-4 pt-4 pb-2 bg-transparent"
    : "flex flex-col items-center justify-start w-full px-4 pt-2 pb-4 bg-transparent";
  
  // Dynamic arrow positioning to align with tray icon
  const ARROW_HALF_SIZE_PX = 7;
  const PANEL_HORIZONTAL_PADDING_PX = 16; // px-4
  const PANEL_VERTICAL_PADDING_PX = 16; // py-4
  const arrowStyle = arrowOffset !== null
    ? isSideTaskbar
      ? ({
          alignSelf: "flex-start",
          marginTop: `${arrowOffset - ARROW_HALF_SIZE_PX - PANEL_VERTICAL_PADDING_PX}px`,
        } as const)
      : ({
          alignSelf: "flex-start",
          marginLeft: `${arrowOffset - ARROW_HALF_SIZE_PX - PANEL_HORIZONTAL_PADDING_PX}px`,
        } as const)
    : undefined;

  return (
    <div ref={containerRef} className={containerClasses}>
      {/* macOS: top arrow; Windows: top/bottom/side based on taskbar */}
      {(!isWindows || isTopTaskbar) && <div className="tray-arrow" style={arrowStyle} />}
      {isWindows && isLeftTaskbar && <div className="tray-arrow-left" style={arrowStyle} />}
      <div
        className="relative bg-card rounded-xl overflow-hidden select-none w-full flex flex-col"
        style={{ 
          maxHeight: maxPanelHeightPx ? `${maxPanelHeightPx - ARROW_OVERHEAD_PX}px` : undefined,
          boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.25)',
          border: '1px solid rgba(0,0,0,0.08)'
        }}
      >
        <div className="flex flex-1 min-h-0 flex-row">
          <SideNav
            activeView={activeView}
            onViewChange={setActiveView}
            plugins={navPlugins}
          />
          <div className="flex-1 flex flex-col px-3 pt-2 pb-1.5 min-w-0 bg-card dark:bg-muted/50">
            <div className="relative flex-1 min-h-0">
              <div ref={scrollRef} className="h-full overflow-y-auto scrollbar-none">
                {renderContent()}
              </div>
              <div className={`pointer-events-none absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-card dark:from-muted/50 to-transparent transition-opacity duration-200 ${canScrollDown ? "opacity-100" : "opacity-0"}`} />
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
      {isWindows && isRightTaskbar && <div className="tray-arrow-right" style={arrowStyle} />}
      {/* Windows: Arrow at bottom pointing down toward taskbar */}
      {isWindows && !isSideTaskbar && !isTopTaskbar && <div className="tray-arrow-down" style={arrowStyle} />}
    </div>
  );
}

export { App };
