import { useEffect, useState } from "react"
import { getVersion } from "@tauri-apps/api/app"

export function useAppVersion() {
  const [appVersion, setAppVersion] = useState("...")

  useEffect(() => {
    getVersion().then(setAppVersion)
  }, [])

  return appVersion
}
