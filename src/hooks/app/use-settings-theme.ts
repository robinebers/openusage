import { useEffect } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import type { ThemeMode } from "@/lib/settings"

export function useSettingsTheme(themeMode: ThemeMode) {
  useEffect(() => {
    const root = document.documentElement
    const glass = themeMode === "glass"

    const apply = (dark: boolean) => {
      root.classList.toggle("dark", dark)
      root.classList.toggle("glass", glass)
    }

    if (themeMode === "light") {
      apply(false)
      if (isTauri()) {
        invoke("set_liquid_glass_enabled", { enabled: false }).catch((error) => {
          console.error("Failed to update liquid glass mode:", error)
        })
      }
      return
    }
    if (themeMode === "dark") {
      apply(true)
      if (isTauri()) {
        invoke("set_liquid_glass_enabled", { enabled: false }).catch((error) => {
          console.error("Failed to update liquid glass mode:", error)
        })
      }
      return
    }

    if (isTauri()) {
      invoke("set_liquid_glass_enabled", { enabled: glass }).catch((error) => {
        console.error("Failed to update liquid glass mode:", error)
      })
    }

    const mq = window.matchMedia("(prefers-color-scheme: dark)")
    apply(mq.matches)
    const handler = (e: MediaQueryListEvent) => apply(e.matches)
    mq.addEventListener("change", handler)
    return () => mq.removeEventListener("change", handler)
  }, [themeMode])
}
