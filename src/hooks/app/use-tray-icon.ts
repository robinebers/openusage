import { useCallback, useEffect, useRef, useState } from "react"
import { resolveResource } from "@tauri-apps/api/path"
import { TrayIcon } from "@tauri-apps/api/tray"
import type { PluginMeta } from "@/lib/plugin-types"
import type { DisplayMode, PluginSettings } from "@/lib/settings"
import { getEnabledPluginIds } from "@/lib/settings"
import { getTrayIconSizePx, renderTrayBarsIcon, type TrayGridCell } from "@/lib/tray-bars-icon"
import { getTrayPrimaryBars } from "@/lib/tray-primary-progress"
import type { PluginState } from "@/hooks/app/types"

type TrayUpdateReason = "probe" | "settings" | "init"

type UseTrayIconArgs = {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginState>
  displayMode: DisplayMode
  activeView: string
  showTrayIcon: boolean
}

export function useTrayIcon({
  pluginsMeta,
  pluginSettings,
  pluginStates,
  displayMode,
  activeView,
  showTrayIcon,
}: UseTrayIconArgs) {
  const trayRef = useRef<TrayIcon | null>(null)
  const trayGaugeIconPathRef = useRef<string | null>(null)
  const trayUpdateTimerRef = useRef<number | null>(null)
  const trayUpdatePendingRef = useRef(false)
  const trayUpdateQueuedRef = useRef(false)
  const [trayReady, setTrayReady] = useState(false)

  const pluginsMetaRef = useRef(pluginsMeta)
  const pluginSettingsRef = useRef(pluginSettings)
  const pluginStatesRef = useRef(pluginStates)
  const displayModeRef = useRef(displayMode)
  const activeViewRef = useRef(activeView)
  const showTrayIconRef = useRef(showTrayIcon)
  const lastTrayProviderIdRef = useRef<string | null>(null)

  useEffect(() => {
    pluginsMetaRef.current = pluginsMeta
  }, [pluginsMeta])

  useEffect(() => {
    pluginSettingsRef.current = pluginSettings
  }, [pluginSettings])

  useEffect(() => {
    pluginStatesRef.current = pluginStates
  }, [pluginStates])

  useEffect(() => {
    displayModeRef.current = displayMode
  }, [displayMode])

  useEffect(() => {
    activeViewRef.current = activeView
  }, [activeView])

  useEffect(() => {
    showTrayIconRef.current = showTrayIcon
  }, [showTrayIcon])

  const scheduleTrayIconUpdate = useCallback((
    _reason: TrayUpdateReason,
    delayMs = 0,
  ) => {
    if (trayUpdateTimerRef.current !== null) {
      window.clearTimeout(trayUpdateTimerRef.current)
      trayUpdateTimerRef.current = null
    }

    trayUpdateTimerRef.current = window.setTimeout(() => {
      trayUpdateTimerRef.current = null
      if (trayUpdatePendingRef.current) {
        trayUpdateQueuedRef.current = true
        return
      }
      trayUpdatePendingRef.current = true

      const finalizeUpdate = () => {
        trayUpdatePendingRef.current = false
        if (!trayUpdateQueuedRef.current) return
        trayUpdateQueuedRef.current = false
        scheduleTrayIconUpdate("probe", 0)
      }

      const tray = trayRef.current
      if (!tray) {
        finalizeUpdate()
        return
      }

      const maybeSetTitle =
        (tray as TrayIcon & { setTitle?: (value: string | null) => Promise<void> }).setTitle
      const setTitleFn =
        typeof maybeSetTitle === "function"
          ? (value: string | null) => maybeSetTitle.call(tray, value)
          : null
      const setTrayTitle = (title: string | null) => {
        if (setTitleFn) {
          return setTitleFn(title)
        }
        return Promise.resolve()
      }

      const restoreGaugeIcon = () => {
        const gaugePath = trayGaugeIconPathRef.current
        if (gaugePath) {
          Promise.all([
            tray.setIcon(gaugePath),
            tray.setIconAsTemplate(true),
            setTrayTitle(""),
          ])
            .catch((e) => {
              console.error("Failed to restore tray gauge icon:", e)
            })
            .finally(() => {
              finalizeUpdate()
            })
        } else {
          finalizeUpdate()
        }
      }

      const currentSettings = pluginSettingsRef.current
      if (!currentSettings) {
        restoreGaugeIcon()
        return
      }

      const enabledPluginIds = getEnabledPluginIds(currentSettings)
      if (enabledPluginIds.length === 0) {
        restoreGaugeIcon()
        return
      }

      const nextActiveView = activeViewRef.current
      const activeProviderId =
        nextActiveView !== "home" && nextActiveView !== "settings" ? nextActiveView : null

      let trayProviderId: string | null = null
      if (activeProviderId && enabledPluginIds.includes(activeProviderId)) {
        trayProviderId = activeProviderId
      } else if (
        lastTrayProviderIdRef.current &&
        enabledPluginIds.includes(lastTrayProviderIdRef.current)
      ) {
        trayProviderId = lastTrayProviderIdRef.current
      } else {
        trayProviderId = enabledPluginIds[0] ?? null
      }

      if (!trayProviderId) {
        restoreGaugeIcon()
        return
      }
      lastTrayProviderIdRef.current = trayProviderId

      const bars = getTrayPrimaryBars({
        pluginsMeta: pluginsMetaRef.current,
        pluginSettings: currentSettings,
        pluginStates: pluginStatesRef.current,
        maxBars: 1,
        displayMode: displayModeRef.current,
        pluginId: trayProviderId,
      })

      const items = bars[0]?.items || []

      let tooltipText: string | undefined
      let gridCellsToRender: TrayGridCell[] = []
      let providerIconUrlToRender = pluginsMetaRef.current.find((plugin) => plugin.id === trayProviderId)?.iconUrl

      if (items.length > 0) {
        tooltipText = items.map(item => {
          const hasFraction = typeof item.fraction === "number" && Number.isFinite(item.fraction)
          const clampedFraction = hasFraction ? Math.max(0, Math.min(1, item.fraction!)) : undefined
          return `${item.label}: ${typeof clampedFraction === "number" ? Math.round(clampedFraction * 100) + '%' : '--%'}`
        }).join("\n")

        gridCellsToRender = items.map(item => {
          const hasFraction = typeof item.fraction === "number" && Number.isFinite(item.fraction)
          const clampedFraction = hasFraction ? Math.max(0, Math.min(1, item.fraction!)) : undefined
          const valStr = typeof clampedFraction === "number" ? `${Math.round(clampedFraction * 100)}%` : "--%"

          if (items.length === 1) {
            return { text: valStr }
          }

          let shortLabel = item.label
          const words = shortLabel.split(" ")
          if (words.length > 1) {
            shortLabel = words[words.length - 1] // e.g. "Gemini Flash" -> "Flash"
          }
          if (shortLabel.length > 5) {
            shortLabel = shortLabel.substring(0, 3) // e.g. "Session" -> "Ses", "Weekly" -> "Wee"
          }
          // The user specifically requested a space here ("加一个空格以美化展示效果")
          return { text: `${shortLabel} ${valStr}` }
        })
      }

      const sizePx = getTrayIconSizePx(window.devicePixelRatio)

      renderTrayBarsIcon({
        sizePx,
        gridCells: gridCellsToRender,
        providerIconUrl: showTrayIconRef.current ? providerIconUrlToRender : undefined,
        hideIcon: !showTrayIconRef.current,
      })
        .then(async (img) => {
          await tray.setIcon(img)
          await tray.setIconAsTemplate(true)
          await setTrayTitle(null) // Disabling native Title clipping entirely
          const maybeSetTooltip =
            (tray as TrayIcon & { setTooltip?: (value: string | null) => Promise<void> }).setTooltip
          if (typeof maybeSetTooltip === "function") {
            // If tooltip is null, clear current tooltip.
            await maybeSetTooltip.call(tray, tooltipText ?? null).catch((error) => {
              console.error("Failed to update tray tooltip:", error)
            })
          }
        })
        .catch((e) => {
          console.error("Failed to update tray icon:", e)
        })
        .finally(() => {
          finalizeUpdate()
        })
    }, delayMs)
  }, [])

  const trayInitializedRef = useRef(false)
  useEffect(() => {
    if (trayInitializedRef.current) return
    let cancelled = false

      ; (async () => {
        try {
          const tray = await TrayIcon.getById("tray")
          if (cancelled) return
          trayRef.current = tray
          trayInitializedRef.current = true

          try {
            trayGaugeIconPathRef.current = await resolveResource("icons/tray-icon.png")
          } catch (e) {
            console.error("Failed to resolve tray gauge icon resource:", e)
          }

          if (cancelled) return
          setTrayReady(true)
        } catch (e) {
          console.error("Failed to load tray icon handle:", e)
        }
      })()

    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    if (!trayReady) return
    if (!pluginSettings) return
    if (pluginsMeta.length === 0) return
    scheduleTrayIconUpdate("init", 0)
  }, [pluginsMeta.length, pluginSettings, scheduleTrayIconUpdate, trayReady])

  useEffect(() => {
    if (!trayReady) return
    scheduleTrayIconUpdate("settings", 0)
  }, [activeView, scheduleTrayIconUpdate, trayReady])

  useEffect(() => {
    return () => {
      if (trayUpdateTimerRef.current !== null) {
        window.clearTimeout(trayUpdateTimerRef.current)
        trayUpdateTimerRef.current = null
      }
      trayUpdatePendingRef.current = false
      trayUpdateQueuedRef.current = false
    }
  }, [])

  return {
    scheduleTrayIconUpdate,
  }
}
