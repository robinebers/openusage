import { useEffect, useState } from "react"
import { getVersion } from "@tauri-apps/api/app"

export function useAppVersion() {
  const [appVersion, setAppVersion] = useState("...")

  useEffect(() => {
    getVersion()
      .then(setAppVersion)
      .catch((error) => {
        console.error("Failed to get app version:", error)
      })
  }, [])

  return appVersion
}
