import { useEffect } from "react"
import { isTauri } from "@tauri-apps/api/core"
import { requestPermission } from "@tauri-apps/plugin-notification"

export function useNotificationPermission() {
  useEffect(() => {
    if (!isTauri()) return

    void requestPermission().catch((error) => {
      console.error("Failed to request notification permission:", error)
    })
  }, [])
}
