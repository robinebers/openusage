import { useEffect, useState } from "react"

const query = "(prefers-color-scheme: dark)"

export function useDarkMode(): boolean {
  const [isDark, setIsDark] = useState(
    () => typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(query).matches
  )

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return
    const mql = window.matchMedia(query)
    const handler = (e: MediaQueryListEvent) => setIsDark(e.matches)
    mql.addEventListener("change", handler)
    return () => mql.removeEventListener("change", handler)
  }, [])

  return isDark
}
