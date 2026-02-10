import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { getCurrentWindow, PhysicalSize, currentMonitor } from "@tauri-apps/api/window"
import { getVersion } from "@tauri-apps/api/app"
import { resolveResource } from "@tauri-apps/api/path"
import { TrayIcon } from "@tauri-apps/api/tray"
import {
  disable as disableAutostart,
  enable as enableAutostart,
  isEnabled as isAutostartEnabled,
} from "@tauri-apps/plugin-autostart"
import { SideNav, type ActiveView } from "@/components/side-nav"
import { PanelFooter } from "@/components/panel-footer"
import { OverviewPage } from "@/pages/overview"
import { ProviderDetailPage } from "@/pages/provider-detail"
import { SettingsPage } from "@/pages/settings"
import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import { track } from "@/lib/analytics"
import { getTrayIconSizePx, renderTrayBarsIcon } from "@/lib/tray-bars-icon"
import { getTrayPrimaryBars } from "@/lib/tray-primary-progress"
import { useProbeEvents } from "@/hooks/use-probe-events"
import { useAppUpdate } from "@/hooks/use-app-update"
import {
  arePluginSettingsEqual,
  DEFAULT_AUTO_UPDATE_INTERVAL,
  DEFAULT_DISPLAY_MODE,
  DEFAULT_GLOBAL_SHORTCUT,
  DEFAULT_RESET_TIMER_DISPLAY_MODE,
  DEFAULT_START_ON_LOGIN,
  DEFAULT_TRAY_ICON_STYLE,
  DEFAULT_TRAY_SHOW_PERCENTAGE,
  DEFAULT_THEME_MODE,
  REFRESH_COOLDOWN_MS,
  getEnabledPluginIds,
  isTrayPercentageMandatory,
  loadAutoUpdateInterval,
  loadCliProxyAccountSelections,
  loadDisplayMode,
  loadGlobalShortcut,
  loadPluginSettings,
  loadResetTimerDisplayMode,
  loadStartOnLogin,
  loadTrayShowPercentage,
  loadTrayIconStyle,
  loadThemeMode,
  normalizePluginSettings,
  saveAutoUpdateInterval,
  saveCliProxyAccountSelections,
  saveDisplayMode,
  saveGlobalShortcut,
  savePluginSettings,
  saveResetTimerDisplayMode,
  saveStartOnLogin,
  saveTrayShowPercentage,
  saveTrayIconStyle,
  saveThemeMode,
  type AutoUpdateIntervalMinutes,
  type CliProxyAccountSelections,
  type DisplayMode,
  type GlobalShortcut,
  type PluginSettings,
  type ResetTimerDisplayMode,
  type TrayIconStyle,
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

type CliProxyConfigView = {
  configured: boolean
  baseUrl: string | null
}

type CliProxyAuthFile = {
  id: string
  name: string
  provider: string
  email?: string | null
  authIndex?: string | null
  disabled: boolean
  unavailable: boolean
  runtimeOnly?: boolean
}

type AccountOption = {
  value: string
  label: string
}

const OVERLAY_ENABLED_PLUGIN_IDS = new Set(["codex", "claude", "kimi", "antigravity"])
const HIDDEN_PLUGIN_IDS = new Set(["cliproxyapi"])
const LOCAL_ACCOUNT_VALUE = "__local__"
const LOCAL_ACCOUNT_LABEL = "Local account"

function mapAuthProviderToPluginId(provider: string) {
  const normalized = provider.trim().toLowerCase()
  if (normalized === "anthropic") return "claude"
  return normalized
}

function buildAccountOptionsByPlugin(authFiles: CliProxyAuthFile[]) {
  const byPlugin: Record<string, AccountOption[]> = {}
  const seen: Record<string, Set<string>> = {}

  for (const pluginId of OVERLAY_ENABLED_PLUGIN_IDS) {
    byPlugin[pluginId] = [{ value: LOCAL_ACCOUNT_VALUE, label: LOCAL_ACCOUNT_LABEL }]
    seen[pluginId] = new Set([LOCAL_ACCOUNT_VALUE])
  }

  for (const file of authFiles) {
    if (file.disabled || file.unavailable) continue
    if (!file.name || !file.name.toLowerCase().endsWith(".json")) continue

    const pluginId = mapAuthProviderToPluginId(file.provider || "")
    if (!OVERLAY_ENABLED_PLUGIN_IDS.has(pluginId)) continue

    const rawSelection = (file.authIndex || file.id || file.name || "").trim()
    if (!rawSelection) continue

    const label = file.email?.trim()
      ? `${file.email.trim()} (${file.name})`
      : file.name

    if (!seen[pluginId]) seen[pluginId] = new Set<string>()
    if (seen[pluginId].has(rawSelection)) continue
    seen[pluginId].add(rawSelection)

    if (!byPlugin[pluginId]) byPlugin[pluginId] = []
    byPlugin[pluginId].push({ value: rawSelection, label })
  }

  return byPlugin
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
  const [resetTimerDisplayMode, setResetTimerDisplayMode] = useState<ResetTimerDisplayMode>(
    DEFAULT_RESET_TIMER_DISPLAY_MODE
  )
  const [trayIconStyle, setTrayIconStyle] = useState<TrayIconStyle>(DEFAULT_TRAY_ICON_STYLE)
  const [trayShowPercentage, setTrayShowPercentage] = useState(DEFAULT_TRAY_SHOW_PERCENTAGE)
  const [globalShortcut, setGlobalShortcut] = useState<GlobalShortcut>(DEFAULT_GLOBAL_SHORTCUT)
  const [startOnLogin, setStartOnLogin] = useState(DEFAULT_START_ON_LOGIN)
  const [maxPanelHeightPx, setMaxPanelHeightPx] = useState<number | null>(null)
  const maxPanelHeightPxRef = useRef<number | null>(null)
  const [appVersion, setAppVersion] = useState("...")
  const [cliProxyConfigured, setCliProxyConfigured] = useState(false)
  const [cliProxyBaseUrl, setCliProxyBaseUrl] = useState("")
  const [cliProxyApiKey, setCliProxyApiKey] = useState("")
  const [cliProxyAuthFiles, setCliProxyAuthFiles] = useState<CliProxyAuthFile[]>([])
  const [cliProxyBusy, setCliProxyBusy] = useState(false)
  const [cliProxyError, setCliProxyError] = useState<string | null>(null)
  const [cliProxySelections, setCliProxySelections] = useState<CliProxyAccountSelections>({})

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
  const displayModeRef = useRef(displayMode)
  const trayIconStyleRef = useRef(trayIconStyle)
  const trayShowPercentageRef = useRef(trayShowPercentage)
  const cliProxySelectionsRef = useRef<CliProxyAccountSelections>(cliProxySelections)
  useEffect(() => { pluginsMetaRef.current = pluginsMeta }, [pluginsMeta])
  useEffect(() => { pluginSettingsRef.current = pluginSettings }, [pluginSettings])
  useEffect(() => { pluginStatesRef.current = pluginStates }, [pluginStates])
  useEffect(() => { displayModeRef.current = displayMode }, [displayMode])
  useEffect(() => { trayIconStyleRef.current = trayIconStyle }, [trayIconStyle])
  useEffect(() => { trayShowPercentageRef.current = trayShowPercentage }, [trayShowPercentage])
  useEffect(() => { cliProxySelectionsRef.current = cliProxySelections }, [cliProxySelections])

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

      const style = trayIconStyleRef.current
      const maxBars = style === "bars" ? 4 : 1
      const bars = getTrayPrimaryBars({
        pluginsMeta: pluginsMetaRef.current,
        pluginSettings: pluginSettingsRef.current,
        pluginStates: pluginStatesRef.current,
        maxBars,
        displayMode: displayModeRef.current,
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

      const percentageMandatory = isTrayPercentageMandatory(style)

      let percentText: string | undefined
      if (percentageMandatory || trayShowPercentageRef.current) {
        const firstFraction = bars[0]?.fraction
        if (typeof firstFraction === "number" && Number.isFinite(firstFraction)) {
          const clamped = Math.max(0, Math.min(1, firstFraction))
          const rounded = Math.round(clamped * 100)
          percentText = `${rounded}%`
        }
      }

      if (style === "textOnly" && !percentText) {
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
      const firstProviderId = bars[0]?.id
      const providerIconUrl =
        style === "provider"
          ? pluginsMetaRef.current.find((plugin) => plugin.id === firstProviderId)?.iconUrl
          : undefined

      renderTrayBarsIcon({ bars, sizePx, style, percentText, providerIconUrl })
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
      .filter((id) => !disabledSet.has(id) && !HIDDEN_PLUGIN_IDS.has(id))
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
      .filter((id) => !disabledSet.has(id) && !HIDDEN_PLUGIN_IDS.has(id))
      .map((id) => metaById.get(id))
      .filter((p): p is PluginMeta => Boolean(p))
      .map((p) => ({ id: p.id, name: p.name, iconUrl: p.iconUrl, brandColor: p.brandColor }))
  }, [pluginSettings, pluginsMeta])

  const accountOptionsByPlugin = useMemo(
    () => buildAccountOptionsByPlugin(cliProxyAuthFiles),
    [cliProxyAuthFiles]
  )

  const selectedAccountByPlugin = useMemo(() => {
    const selected: Record<string, string> = {}
    for (const [pluginId, options] of Object.entries(accountOptionsByPlugin)) {
      if (options.length === 0) continue
      const configured = (cliProxySelections[pluginId] || "").trim()
      if (configured && options.some((option) => option.value === configured)) {
        selected[pluginId] = configured
      } else {
        selected[pluginId] = options[0].value
      }
    }
    return selected
  }, [accountOptionsByPlugin, cliProxySelections])

  // Track page views
  useEffect(() => {
    const page =
      activeView === "home" ? "overview"
        : activeView === "settings" ? "settings"
          : "provider_detail"
    const props: Record<string, string> =
      activeView !== "home" && activeView !== "settings"
        ? { page, provider_id: activeView }
        : { page }
    track("page_viewed", props)
  }, [activeView])

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

  const applyStartOnLogin = useCallback(async (value: boolean) => {
    if (!isTauri()) return
    const currentlyEnabled = await isAutostartEnabled()
    if (currentlyEnabled === value) return

    if (value) {
      await enableAutostart()
      return
    }
    await disableAutostart()
  }, [])

  const startBatchWithSelections = useCallback(
    (pluginIds?: string[], selections?: CliProxyAccountSelections) => {
      const accountSelections = selections ?? cliProxySelectionsRef.current
      const cliProxySelectionsOnly = Object.fromEntries(
        Object.entries(accountSelections).filter(
          ([pluginId, value]) =>
            OVERLAY_ENABLED_PLUGIN_IDS.has(pluginId) &&
            typeof value === "string" &&
            value.trim() !== "" &&
            value !== LOCAL_ACCOUNT_VALUE
        )
      )
      return startBatch(pluginIds, {
        accountSelections: cliProxySelectionsOnly,
      })
    },
    [startBatch]
  )

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

        let storedDisplayMode = DEFAULT_DISPLAY_MODE
        try {
          storedDisplayMode = await loadDisplayMode()
        } catch (error) {
          console.error("Failed to load display mode:", error)
        }

        let storedResetTimerDisplayMode = DEFAULT_RESET_TIMER_DISPLAY_MODE
        try {
          storedResetTimerDisplayMode = await loadResetTimerDisplayMode()
        } catch (error) {
          console.error("Failed to load reset timer display mode:", error)
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

        let storedGlobalShortcut = DEFAULT_GLOBAL_SHORTCUT
        try {
          storedGlobalShortcut = await loadGlobalShortcut()
        } catch (error) {
          console.error("Failed to load global shortcut:", error)
        }

        let storedStartOnLogin = DEFAULT_START_ON_LOGIN
        try {
          storedStartOnLogin = await loadStartOnLogin()
        } catch (error) {
          console.error("Failed to load start on login:", error)
        }

        try {
          await applyStartOnLogin(storedStartOnLogin)
        } catch (error) {
          console.error("Failed to apply start on login setting:", error)
        }

        let storedCliProxySelections: CliProxyAccountSelections = {}
        try {
          storedCliProxySelections = await loadCliProxyAccountSelections()
        } catch (error) {
          console.error("Failed to load CLIProxy account selections:", error)
        }

        let cliProxyConfig: CliProxyConfigView = { configured: false, baseUrl: null }
        try {
          cliProxyConfig = await invoke<CliProxyConfigView>("cliproxyapi_get_config")
        } catch (error) {
          console.error("Failed to load CLIProxy config:", error)
        }

        let authFiles: CliProxyAuthFile[] = []
        if (cliProxyConfig.configured) {
          try {
            authFiles = await invoke<CliProxyAuthFile[]>("cliproxyapi_list_auth_files")
          } catch (error) {
            console.error("Failed to load CLIProxy auth files:", error)
          }
        }

        const accountOptionsByPlugin = buildAccountOptionsByPlugin(authFiles)
        const effectiveSelections: CliProxyAccountSelections = { ...storedCliProxySelections }
        for (const [pluginId, options] of Object.entries(accountOptionsByPlugin)) {
          if (options.length === 0) continue
          const current = (effectiveSelections[pluginId] || "").trim()
          if (!current) {
            effectiveSelections[pluginId] = options[0].value
            continue
          }
          const exists = options.some((option) => option.value === current)
          if (!exists) {
            effectiveSelections[pluginId] = options[0].value
          }
        }
        for (const pluginId of OVERLAY_ENABLED_PLUGIN_IDS) {
          if (accountOptionsByPlugin[pluginId]?.length) continue
          delete effectiveSelections[pluginId]
        }

        const normalizedTrayShowPercentage = isTrayPercentageMandatory(storedTrayIconStyle)
          ? true
          : storedTrayShowPercentage

        if (isMounted) {
          setPluginSettings(normalized)
          setAutoUpdateInterval(storedInterval)
          setThemeMode(storedThemeMode)
          setDisplayMode(storedDisplayMode)
          setResetTimerDisplayMode(storedResetTimerDisplayMode)
          setTrayIconStyle(storedTrayIconStyle)
          setTrayShowPercentage(normalizedTrayShowPercentage)
          setGlobalShortcut(storedGlobalShortcut)
          setStartOnLogin(storedStartOnLogin)
          setStartOnLogin(storedStartOnLogin)
          setCliProxyConfigured(cliProxyConfig.configured)
          setCliProxyBaseUrl(cliProxyConfig.baseUrl ?? "")
          setCliProxyApiKey("")
          setCliProxyAuthFiles(authFiles)
          setCliProxySelections(effectiveSelections)
          setCliProxyError(null)
          cliProxySelectionsRef.current = effectiveSelections
          void saveCliProxyAccountSelections(effectiveSelections).catch((error) => {
            console.error("Failed to save CLIProxy account selections:", error)
          })
          const enabledIds = getEnabledPluginIds(normalized)
          setLoadingForPlugins(enabledIds)
          try {
            await startBatchWithSelections(enabledIds, effectiveSelections)
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
  }, [setLoadingForPlugins, setErrorForPlugins, startBatchWithSelections, applyStartOnLogin])

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
      startBatchWithSelections(enabledIds).catch((error) => {
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
    startBatchWithSelections,
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

  const startManualRefresh = useCallback(
    (ids: string[], errorMessage: string) => {
      for (const id of ids) {
        manualRefreshIdsRef.current.add(id)
      }
      setLoadingForPlugins(ids)
      startBatchWithSelections(ids).catch((error) => {
        for (const id of ids) {
          manualRefreshIdsRef.current.delete(id)
        }
        console.error(errorMessage, error)
        setErrorForPlugins(ids, "Failed to start probe")
      })
    },
    [setLoadingForPlugins, setErrorForPlugins, startBatchWithSelections]
  )

  const handleRetryPlugin = useCallback(
    (id: string) => {
      track("provider_refreshed", { provider_id: id })
      resetAutoUpdateSchedule()
      startManualRefresh([id], "Failed to retry plugin:")
    },
    [resetAutoUpdateSchedule, startManualRefresh]
  )

  const handleRefreshAll = useCallback(() => {
    if (!pluginSettings) return
    const enabledIds = getEnabledPluginIds(pluginSettings)
    if (enabledIds.length === 0) return
    const now = Date.now()
    const eligibleIds = enabledIds.filter((id) => {
      const currentState = pluginStatesRef.current[id]
      if (currentState?.loading) return false
      if (manualRefreshIdsRef.current.has(id)) return false
      const lastManualRefreshAt = currentState?.lastManualRefreshAt
      if (!lastManualRefreshAt) return true
      return now - lastManualRefreshAt >= REFRESH_COOLDOWN_MS
    })
    if (eligibleIds.length === 0) return

    resetAutoUpdateSchedule()
    startManualRefresh(eligibleIds, "Failed to start refresh batch:")
  }, [
    pluginSettings,
    resetAutoUpdateSchedule,
    startManualRefresh,
  ])

  const handleThemeModeChange = useCallback((mode: ThemeMode) => {
    track("setting_changed", { setting: "theme", value: mode })
    setThemeMode(mode)
    void saveThemeMode(mode).catch((error) => {
      console.error("Failed to save theme mode:", error)
    })
  }, [])

  const handleDisplayModeChange = useCallback((mode: DisplayMode) => {
    track("setting_changed", { setting: "display_mode", value: mode })
    setDisplayMode(mode)
    // Display mode is a direct user-facing toggle; update tray immediately.
    scheduleTrayIconUpdate("settings", 0)
    void saveDisplayMode(mode).catch((error) => {
      console.error("Failed to save display mode:", error)
    })
  }, [scheduleTrayIconUpdate])

  const handleResetTimerDisplayModeChange = useCallback((mode: ResetTimerDisplayMode) => {
    track("setting_changed", { setting: "reset_timer_display_mode", value: mode })
    setResetTimerDisplayMode(mode)
    void saveResetTimerDisplayMode(mode).catch((error) => {
      console.error("Failed to save reset timer display mode:", error)
    })
  }, [])

  const handleResetTimerDisplayModeToggle = useCallback(() => {
    const next = resetTimerDisplayMode === "relative" ? "absolute" : "relative"
    handleResetTimerDisplayModeChange(next)
  }, [handleResetTimerDisplayModeChange, resetTimerDisplayMode])

  const handleTrayIconStyleChange = useCallback((style: TrayIconStyle) => {
    track("setting_changed", { setting: "tray_icon_style", value: style })
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
    track("setting_changed", { setting: "tray_show_percentage", value: value ? "true" : "false" })
    trayShowPercentageRef.current = value
    setTrayShowPercentage(value)
    // Tray icon text visibility is a direct user-facing toggle; update tray immediately.
    scheduleTrayIconUpdate("settings", 0)
    void saveTrayShowPercentage(value).catch((error) => {
      console.error("Failed to save tray show percentage:", error)
    })
  }, [scheduleTrayIconUpdate])

  const handleAutoUpdateIntervalChange = useCallback((value: AutoUpdateIntervalMinutes) => {
    track("setting_changed", { setting: "auto_refresh", value: String(value) })
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

  const handleGlobalShortcutChange = useCallback((value: GlobalShortcut) => {
    track("setting_changed", { setting: "global_shortcut", value: value ?? "disabled" })
    setGlobalShortcut(value)
    void saveGlobalShortcut(value).catch((error) => {
      console.error("Failed to save global shortcut:", error)
    })
    // Update the shortcut registration in the backend
    invoke("update_global_shortcut", { shortcut: value }).catch((error) => {
      console.error("Failed to update global shortcut:", error)
    })
  }, [])

  const handleStartOnLoginChange = useCallback((value: boolean) => {
    track("setting_changed", { setting: "start_on_login", value: value ? "true" : "false" })
    setStartOnLogin(value)
    void saveStartOnLogin(value).catch((error) => {
      console.error("Failed to save start on login:", error)
    })
    void applyStartOnLogin(value).catch((error) => {
      console.error("Failed to update start on login:", error)
    })
  }, [applyStartOnLogin])

  const refreshCliProxyAuthFiles = useCallback(async () => {
    const authFiles = await invoke<CliProxyAuthFile[]>("cliproxyapi_list_auth_files")
    setCliProxyAuthFiles(authFiles)

    const optionsByPlugin = buildAccountOptionsByPlugin(authFiles)
    const nextSelections: CliProxyAccountSelections = { ...cliProxySelectionsRef.current }
    for (const [pluginId, options] of Object.entries(optionsByPlugin)) {
      if (options.length === 0) continue
      const current = (nextSelections[pluginId] || "").trim()
      if (!current || !options.some((option) => option.value === current)) {
        nextSelections[pluginId] = options[0].value
      }
    }
    for (const pluginId of OVERLAY_ENABLED_PLUGIN_IDS) {
      if (optionsByPlugin[pluginId]?.length) continue
      delete nextSelections[pluginId]
    }

    cliProxySelectionsRef.current = nextSelections
    setCliProxySelections(nextSelections)
    await saveCliProxyAccountSelections(nextSelections)
    return { authFiles, nextSelections }
  }, [])

  const handleCliProxySave = useCallback(async () => {
    setCliProxyBusy(true)
    setCliProxyError(null)
    try {
      await invoke("cliproxyapi_set_config", {
        baseUrl: cliProxyBaseUrl,
        apiKey: cliProxyApiKey,
      })

      const config = await invoke<CliProxyConfigView>("cliproxyapi_get_config")
      setCliProxyConfigured(config.configured)
      setCliProxyBaseUrl(config.baseUrl ?? "")
      setCliProxyApiKey("")

      const { nextSelections } = await refreshCliProxyAuthFiles()
      const activePluginSettings = pluginSettingsRef.current
      if (activePluginSettings) {
        const enabledIds = getEnabledPluginIds(activePluginSettings)
        if (enabledIds.length > 0) {
          setLoadingForPlugins(enabledIds)
          await startBatchWithSelections(enabledIds, nextSelections)
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      setCliProxyError(message)
    } finally {
      setCliProxyBusy(false)
    }
  }, [cliProxyApiKey, cliProxyBaseUrl, refreshCliProxyAuthFiles, setLoadingForPlugins, startBatchWithSelections])

  const handleCliProxyRefresh = useCallback(async () => {
    setCliProxyBusy(true)
    setCliProxyError(null)
    try {
      await refreshCliProxyAuthFiles()
      setCliProxyConfigured(true)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      setCliProxyError(message)
    } finally {
      setCliProxyBusy(false)
    }
  }, [refreshCliProxyAuthFiles])

  const handleCliProxyClear = useCallback(async () => {
    setCliProxyBusy(true)
    setCliProxyError(null)
    try {
      await invoke("cliproxyapi_clear_config")
      setCliProxyConfigured(false)
      setCliProxyBaseUrl("")
      setCliProxyApiKey("")
      setCliProxyAuthFiles([])
      const nextSelections: CliProxyAccountSelections = { ...cliProxySelectionsRef.current }
      for (const pluginId of OVERLAY_ENABLED_PLUGIN_IDS) {
        delete nextSelections[pluginId]
      }
      cliProxySelectionsRef.current = nextSelections
      setCliProxySelections(nextSelections)
      await saveCliProxyAccountSelections(nextSelections)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      setCliProxyError(message)
    } finally {
      setCliProxyBusy(false)
    }
  }, [])

  const handleAccountSelectionChange = useCallback(
    (pluginId: string, account: string) => {
      const selected = account.trim()
      const current = (cliProxySelectionsRef.current[pluginId] || "").trim()
      if (!selected || selected === current) return

      const nextSelections: CliProxyAccountSelections = {
        ...cliProxySelectionsRef.current,
        [pluginId]: selected,
      }
      cliProxySelectionsRef.current = nextSelections
      setCliProxySelections(nextSelections)
      void saveCliProxyAccountSelections(nextSelections).catch((error) => {
        console.error("Failed to save CLIProxy account selections:", error)
      })

      setLoadingForPlugins([pluginId])
      startBatchWithSelections([pluginId], nextSelections).catch((error) => {
        console.error("Failed to refresh plugin with selected account:", error)
        setErrorForPlugins([pluginId], "Failed to start probe")
      })
    },
    [setErrorForPlugins, setLoadingForPlugins, startBatchWithSelections]
  )

  const settingsPlugins = useMemo(() => {
    if (!pluginSettings) return []
    const pluginMap = new Map(pluginsMeta.map((plugin) => [plugin.id, plugin]))
    return pluginSettings.order
      .filter((id) => !HIDDEN_PLUGIN_IDS.has(id))
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
      track("providers_reordered", { count: orderedIds.length })
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
      track("provider_toggled", { provider_id: id, enabled: wasDisabled ? "true" : "false" })
      const disabled = new Set(pluginSettings.disabled)

      if (wasDisabled) {
        disabled.delete(id)
        setLoadingForPlugins([id])
        startBatchWithSelections([id]).catch((error) => {
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
    [
      pluginSettings,
      setLoadingForPlugins,
      setErrorForPlugins,
      startBatchWithSelections,
      scheduleTrayIconUpdate,
    ]
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
          resetTimerDisplayMode={resetTimerDisplayMode}
          onResetTimerDisplayModeToggle={handleResetTimerDisplayModeToggle}
          accountOptionsByPlugin={accountOptionsByPlugin}
          selectedAccountByPlugin={selectedAccountByPlugin}
          onAccountChange={handleAccountSelectionChange}
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
          resetTimerDisplayMode={resetTimerDisplayMode}
          onResetTimerDisplayModeChange={handleResetTimerDisplayModeChange}
          trayIconStyle={trayIconStyle}
          onTrayIconStyleChange={handleTrayIconStyleChange}
          trayShowPercentage={trayShowPercentage}
          onTrayShowPercentageChange={handleTrayShowPercentageChange}
          globalShortcut={globalShortcut}
          onGlobalShortcutChange={handleGlobalShortcutChange}
          startOnLogin={startOnLogin}
          onStartOnLoginChange={handleStartOnLoginChange}
          providerIconUrl={navPlugins[0]?.iconUrl}
          cliProxyConfigured={cliProxyConfigured}
          cliProxyBaseUrl={cliProxyBaseUrl}
          cliProxyApiKey={cliProxyApiKey}
          cliProxyAuthFileCount={cliProxyAuthFiles.length}
          cliProxyBusy={cliProxyBusy}
          cliProxyError={cliProxyError}
          onCliProxyBaseUrlChange={setCliProxyBaseUrl}
          onCliProxyApiKeyChange={setCliProxyApiKey}
          onCliProxySave={() => {
            void handleCliProxySave()
          }}
          onCliProxyRefresh={() => {
            void handleCliProxyRefresh()
          }}
          onCliProxyClear={() => {
            void handleCliProxyClear()
          }}
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
        resetTimerDisplayMode={resetTimerDisplayMode}
        onResetTimerDisplayModeToggle={handleResetTimerDisplayModeToggle}
        accountOptions={selectedPlugin ? accountOptionsByPlugin[selectedPlugin.meta.id] : undefined}
        selectedAccount={selectedPlugin ? selectedAccountByPlugin[selectedPlugin.meta.id] : undefined}
        onAccountChange={
          selectedPlugin
            ? (account) => handleAccountSelectionChange(selectedPlugin.meta.id, account)
            : undefined
        }
      />
    )
  }

  return (
    <div ref={containerRef} className="flex flex-col items-center p-6 pt-1.5 bg-transparent">
      <div className="tray-arrow" />
      <div
        className="relative bg-card rounded-xl overflow-hidden select-none w-full border shadow-lg flex flex-col"
        style={maxPanelHeightPx ? { maxHeight: `${maxPanelHeightPx - ARROW_OVERHEAD_PX}px` } : undefined}
      >
        <div className="flex flex-1 min-h-0 flex-row">
          <SideNav
            activeView={activeView}
            onViewChange={setActiveView}
            plugins={navPlugins}
          />
          <div className="flex-1 flex flex-col px-3 pt-2 pb-1.5 min-w-0 bg-card dark:bg-muted/50">
            <div className="relative flex-1 min-h-0">
              <div ref={scrollRef} className="h-full overflow-y-auto overflow-x-hidden scrollbar-none">
                {renderContent()}
              </div>
              <div className={`pointer-events-none absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-card dark:from-muted/50 to-transparent transition-opacity duration-200 ${canScrollDown ? "opacity-100" : "opacity-0"}`} />
            </div>
            <PanelFooter
              version={appVersion}
              autoUpdateNextAt={autoUpdateNextAt}
              updateStatus={updateStatus}
              onUpdateInstall={triggerInstall}
              onUpdateCheck={checkForUpdates}
              onRefreshAll={handleRefreshAll}
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

export { App };
