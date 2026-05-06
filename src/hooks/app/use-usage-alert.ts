import { useCallback, useRef } from "react"
import { convertFileSrc } from "@tauri-apps/api/core"
import type { PluginOutput } from "@/lib/plugin-types"
import { useAppPluginStore } from "@/stores/app-plugin-store"
import { useAppPreferencesStore } from "@/stores/app-preferences-store"

async function sendNotificationAsync(payload: Parameters<
  typeof import("@tauri-apps/plugin-notification").sendNotification
>[0]) {
  const { sendNotification } = await import("@tauri-apps/plugin-notification")
  return sendNotification(payload)
}

export function useUsageAlert() {
  const {
    usageAlertEnabled,
    usageAlertThreshold,
    customUsageAlertThreshold,
    usageAlertSound,
  } = useAppPreferencesStore()

  const { pluginsMeta } = useAppPluginStore()

  const notifiedMapRef = useRef<Record<string, boolean>>({})

  const checkUsageAlert = useCallback(
    (output: PluginOutput) => {
      const sessionLine = output.lines.find(
        (line): line is Extract<(typeof output.lines)[number], { type: "progress" }> =>
          line.type === "progress" && line.label === "Session"
      )
      if (!sessionLine) return
      if (!Number.isFinite(sessionLine.used) || !Number.isFinite(sessionLine.limit)) return
      if (sessionLine.limit <= 0) return

      const usedPercent = (sessionLine.used / sessionLine.limit) * 100
      const remaining = 100 - usedPercent

      const effectiveThreshold =
        usageAlertThreshold === "custom" ? customUsageAlertThreshold : usageAlertThreshold
      if (effectiveThreshold == null) return

      if (remaining > effectiveThreshold) {
        notifiedMapRef.current[output.providerId] = false
        return
      }

      if (!usageAlertEnabled) return
      if (notifiedMapRef.current[output.providerId] === true) return

      const meta = pluginsMeta.find((plugin) => plugin.id === output.providerId)
      const iconFilePath = meta?.iconFilePath

      void sendNotificationAsync({
        title: "Usage Alert",
        body: `Less than ${effectiveThreshold}% remaining on ${output.displayName}`,
        sound: usageAlertSound,
        ...(iconFilePath
          ? { attachments: [{ id: "icon", url: convertFileSrc(iconFilePath) }] }
          : {}),
      })
        .then(() => {
          notifiedMapRef.current[output.providerId] = true
        })
        .catch((error) => {
          console.error("Failed to send usage alert notification:", error)
        })
    },
    [
      customUsageAlertThreshold,
      pluginsMeta,
      usageAlertEnabled,
      usageAlertSound,
      usageAlertThreshold,
    ]
  )

  return { checkUsageAlert }
}

