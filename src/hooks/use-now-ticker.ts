import { useEffect, useState } from "react"

type UseNowTickerOptions = {
  enabled?: boolean
  intervalMs?: number
  stopAfterMs?: number | null
  resetKey?: unknown
}

export function useNowTicker({
  enabled = true,
  intervalMs = 1000,
  stopAfterMs = null,
  resetKey,
}: UseNowTickerOptions = {}) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (!enabled) return undefined

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
  }, [enabled, intervalMs, stopAfterMs, resetKey])

  return now
}
