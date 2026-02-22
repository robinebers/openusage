import { useCallback, useEffect, useRef, useState } from "react"
import { resolveResource } from "@tauri-apps/api/path"
import { TrayIcon } from "@tauri-apps/api/tray"
import type { PluginMeta } from "@/lib/plugin-types"
import type { DisplayMode, PluginSettings, TrayIconStyle } from "@/lib/settings"
import { getTrayIconSizePx, renderTrayBarsIcon } from "@/lib/tray-bars-icon"
import { getTrayPrimaryBars } from "@/lib/tray-primary-progress"
import { isTrayPercentageMandatory } from "@/lib/settings"
import type { PluginState } from "@/hooks/app/types"

type TrayUpdateReason = "probe" | "settings" | "init"

type UseTrayIconArgs = {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginState>
  displayMode: DisplayMode
  trayIconStyle: TrayIconStyle
  trayShowPercentage: boolean
}

export function useTrayIcon({
  pluginsMeta,
  pluginSettings,
  pluginStates,
  displayMode,
  trayIconStyle,
  trayShowPercentage,
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
  const trayIconStyleRef = useRef(trayIconStyle)
  const trayShowPercentageRef = useRef(trayShowPercentage)

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
    trayIconStyleRef.current = trayIconStyle
  }, [trayIconStyle])

  useEffect(() => {
    trayShowPercentageRef.current = trayShowPercentage
  }, [trayShowPercentage])

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

      const style = trayIconStyleRef.current
      const maxBars = style === "bars" ? 4 : 1
      const bars = getTrayPrimaryBars({
        pluginsMeta: pluginsMetaRef.current,
        pluginSettings: pluginSettingsRef.current,
        pluginStates: pluginStatesRef.current,
        maxBars,
        displayMode: displayModeRef.current,
      })

      if (bars.length === 0) {
        const gaugePath = trayGaugeIconPathRef.current
        if (gaugePath) {
          Promise.all([tray.setIcon(gaugePath), tray.setIconAsTemplate(true)])
            .catch((e) => {
              console.error("Failed to restore tray gauge icon:", e)
            })
            .finally(() => {
              finalizeUpdate()
            })
        } else {
          finalizeUpdate()
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
          Promise.all([tray.setIcon(gaugePath), tray.setIconAsTemplate(true)])
            .catch((e) => {
              console.error("Failed to restore tray gauge icon:", e)
            })
            .finally(() => {
              finalizeUpdate()
            })
        } else {
          finalizeUpdate()
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
          finalizeUpdate()
        })
    }, delayMs)
  }, [])

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

  return {
    scheduleTrayIconUpdate,
  }
}
