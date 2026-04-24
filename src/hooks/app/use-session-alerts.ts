import { useEffect, useRef } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { sendNotification, requestPermission } from "@tauri-apps/plugin-notification"
import type { PluginState } from "@/hooks/app/types"
import type { SessionAlertSettings } from "@/lib/settings"
import { buildAlertKey, getNotificationSoundEntry } from "@/lib/notification-sounds"

const ALERT_CHECK_INTERVAL_MS = 30_000
const RESET_ALERT_WINDOW_MS = 30 * 60_000

function getAlertKey(pluginId: string, lineLabel: string, resetsAtIso: string): string {
  return `${pluginId}::${lineLabel}::${resetsAtIso}`
}

async function playBundledSound(fileName: string): Promise<void> {
  try {
    await invoke("play_notification_sound", { fileName })
  } catch (error) {
    console.error("Failed to play bundled alert sound:", error)
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
    if (sessionAlertSettings.enabledAlerts.length === 0) return

    const enabledSet = new Set(sessionAlertSettings.enabledAlerts)
    const pluginIds = new Set(
      sessionAlertSettings.enabledAlerts
        .map((k) => k.split(":", 2)[0])
        .filter((id): id is string => typeof id === "string" && id.length > 0)
    )

    const checkAndAlert = async () => {
      const hasPermission = await ensureNotificationPermission()
      if (!hasPermission) return

      const now = Date.now()

      for (const pluginId of pluginIds) {
        const state = pluginStates[pluginId]
        if (!state?.data) continue

        for (const line of state.data.lines) {
          if (line.type !== "progress" || !line.resetsAt) continue
          if (!enabledSet.has(buildAlertKey(pluginId, line.label))) continue

          const resetsAtMs = Date.parse(line.resetsAt)
          if (!Number.isFinite(resetsAtMs)) continue

          const key = getAlertKey(pluginId, line.label, line.resetsAt)

          if (now >= resetsAtMs && now - resetsAtMs <= RESET_ALERT_WINDOW_MS && !alertedRef.current.has(key)) {
            alertedRef.current.add(key)

            const soundEntry = getNotificationSoundEntry(pluginId, line.label)
            const body = soundEntry?.message ?? `${state.data.displayName} ${line.label} refreshed.`

            try {
              sendNotification({ title: "Limit Refreshed", body })
            } catch (error) {
              console.error("Failed to send notification:", error)
            }

            if (sessionAlertSettings.sound === "bundled" && soundEntry) {
              void playBundledSound(soundEntry.file)
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
