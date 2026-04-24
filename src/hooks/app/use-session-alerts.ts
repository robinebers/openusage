import { useEffect, useRef } from "react"
import { isTauri } from "@tauri-apps/api/core"
import { sendNotification, requestPermission } from "@tauri-apps/plugin-notification"
import type { PluginState } from "@/hooks/app/types"
import type { SessionAlertSettings } from "@/lib/settings"

const ALERT_CHECK_INTERVAL_MS = 30_000

function getAlertKey(pluginId: string, lineLabel: string, resetsAtIso: string): string {
  return `${pluginId}::${lineLabel}::${resetsAtIso}`
}

async function playCustomSound(path: string | null): Promise<void> {
  if (!path) return
  try {
    const audio = new Audio(path)
    await audio.play()
  } catch (error) {
    console.error("Failed to play custom alert sound:", error)
  }
}

async function ensureNotificationPermission(): Promise<boolean> {
  if (!isTauri()) return false
  try {
    const permission = await requestPermission()
    return permission === "granted"
  } catch (error) {
    console.error("Failed to request notification permission:", error)
    return false
  }
}

export function useSessionAlerts({
  pluginStates,
  sessionAlertSettings,
}: {
  pluginStates: Record<string, PluginState>
  sessionAlertSettings: SessionAlertSettings
}) {
  const alertedRef = useRef<Set<string>>(new Set())

  useEffect(() => {
    if (sessionAlertSettings.enabledPluginIds.length === 0) return

    const checkAndAlert = async () => {
      const hasPermission = await ensureNotificationPermission()
      if (!hasPermission) return

      const now = Date.now()
      const leadMs = sessionAlertSettings.minutesBefore * 60_000

      for (const pluginId of sessionAlertSettings.enabledPluginIds) {
        const state = pluginStates[pluginId]
        if (!state?.data) continue

        for (const line of state.data.lines) {
          if (line.type !== "progress" || !line.resetsAt) continue

          const resetsAtMs = Date.parse(line.resetsAt)
          if (!Number.isFinite(resetsAtMs)) continue

          const alertAt = resetsAtMs - leadMs
          const key = getAlertKey(pluginId, line.label, line.resetsAt)

          if (now >= alertAt && now < resetsAtMs && !alertedRef.current.has(key)) {
            alertedRef.current.add(key)

            const body = `${state.data.displayName} — ${line.label} resets in ${sessionAlertSettings.minutesBefore} min`

            try {
              sendNotification({ title: "Session Resetting Soon", body })
            } catch (error) {
              console.error("Failed to send notification:", error)
            }

            if (sessionAlertSettings.sound === "custom") {
              void playCustomSound(sessionAlertSettings.customSoundPath)
            }
          }
        }
      }
    }

    checkAndAlert()
    const interval = setInterval(checkAndAlert, ALERT_CHECK_INTERVAL_MS)
    return () => clearInterval(interval)
  }, [pluginStates, sessionAlertSettings])
}
