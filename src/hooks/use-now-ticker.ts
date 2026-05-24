import { useEffect, useState } from "react"

type UseNowTickerOptions = {
  enabled?: boolean
  intervalMs?: number
  stopAfterMs?: number | null
  pauseWhenHidden?: boolean
  resetKey?: unknown
}

function isDocumentVisible() {
  if (typeof document === "undefined") return true
  return !document.hidden
}

export function useNowTicker({
  enabled = true,
  intervalMs = 1000,
  stopAfterMs = null,
  pauseWhenHidden = true,
  resetKey,
}: UseNowTickerOptions = {}) {
  const [now, setNow] = useState(() => Date.now())
  const [documentVisible, setDocumentVisible] = useState(() =>
    pauseWhenHidden ? isDocumentVisible() : true
  )

  useEffect(() => {
    if (!pauseWhenHidden || typeof document === "undefined") {
      setDocumentVisible(true)
      return undefined
    }

    const handleVisibilityChange = () => {
      const visible = isDocumentVisible()
      setDocumentVisible(visible)
      if (visible && enabled) {
        setNow(Date.now())
      }
    }

    handleVisibilityChange()
    document.addEventListener("visibilitychange", handleVisibilityChange)
    return () => document.removeEventListener("visibilitychange", handleVisibilityChange)
  }, [enabled, pauseWhenHidden])

  useEffect(() => {
    if (!enabled || !documentVisible) return undefined

    setNow(Date.now())
    const interval = window.setInterval(() => setNow(Date.now()), intervalMs)

    if (stopAfterMs === null || stopAfterMs === undefined) {
      return () => window.clearInterval(interval)
    }

    if (stopAfterMs <= 0) {
      window.clearInterval(interval)
      return undefined
    }

    const timeout = window.setTimeout(() => window.clearInterval(interval), stopAfterMs)
    return () => {
      window.clearInterval(interval)
      window.clearTimeout(timeout)
    }
  }, [enabled, intervalMs, stopAfterMs, resetKey, documentVisible])

  return now
}
