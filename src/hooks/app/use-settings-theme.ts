import { useEffect } from "react"
import type { ThemeMode } from "@/lib/settings"

export function useSettingsTheme(themeMode: ThemeMode) {
  useEffect(() => {
    const root = document.documentElement
    const apply = (dark: boolean) => {
      root.classList.toggle("dark", dark)
    }

    if (themeMode === "light") {
      apply(false)
      return
    }
    if (themeMode === "dark") {
      apply(true)
      return
    }

    const mq = window.matchMedia("(prefers-color-scheme: dark)")
    apply(mq.matches)
    const handler = (e: MediaQueryListEvent) => apply(e.matches)
    mq.addEventListener("change", handler)
    return () => mq.removeEventListener("change", handler)
  }, [themeMode])
}
