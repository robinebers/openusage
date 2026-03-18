import { renderHook, act } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { useNowTicker } from "./use-now-ticker"

describe("useNowTicker", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("does not tick when disabled", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-03T00:00:00.000Z"))

    const { result } = renderHook(() => useNowTicker({ enabled: false, intervalMs: 1000 }))
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))

    act(() => {
      vi.advanceTimersByTime(5_000)
    })

    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))
  })

  it("stops immediately when stopAfterMs is non-positive", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-03T00:00:00.000Z"))

    const { result } = renderHook(() => useNowTicker({ intervalMs: 1000, stopAfterMs: 0 }))
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))

    act(() => {
      vi.setSystemTime(new Date("2026-02-03T00:00:05.000Z"))
      vi.advanceTimersByTime(5_000)
    })

    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))
  })
})
