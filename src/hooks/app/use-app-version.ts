import { useEffect, useState } from "react"
import { getVersion } from "@tauri-apps/api/app"
import { canUseLocalUsageApi } from "@/lib/local-usage-api"

export function useAppVersion() {
  const [appVersion, setAppVersion] = useState("...")

  useEffect(() => {
    if (canUseLocalUsageApi()) return
    getVersion()
      .then(setAppVersion)
      .catch((error) => {
        console.error("Failed to get app version:", error)
      })
  }, [])

  return appVersion
}
