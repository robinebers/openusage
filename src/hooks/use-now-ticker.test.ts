import { renderHook, act } from "@testing-library/react"
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { useNowTicker } from "./use-now-ticker"

describe("useNowTicker", () => {
  let originalDocumentHiddenDescriptor: PropertyDescriptor | undefined

  beforeAll(() => {
    originalDocumentHiddenDescriptor = Object.getOwnPropertyDescriptor(document, "hidden")
  })

  afterEach(() => {
    if (originalDocumentHiddenDescriptor) {
      Object.defineProperty(document, "hidden", originalDocumentHiddenDescriptor)
    } else {
      Reflect.deleteProperty(document, "hidden")
    }
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
      vi.advanceTimersByTime(5_000)
    })

    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))
  })

  it("pauses ticks while the document is hidden", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-03T00:00:00.000Z"))
    Object.defineProperty(document, "hidden", {
      configurable: true,
      value: true,
    })

    const { result } = renderHook(() => useNowTicker({ intervalMs: 1000 }))
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))

    act(() => {
      vi.advanceTimersByTime(5_000)
    })
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))

    const visibleNow = Date.now()
    act(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        value: false,
      })
      document.dispatchEvent(new Event("visibilitychange"))
    })
    expect(result.current).toBe(visibleNow)
  })

  it("does not refresh when disabled and the document becomes visible", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-03T00:00:00.000Z"))
    Object.defineProperty(document, "hidden", {
      configurable: true,
      value: true,
    })

    const { result } = renderHook(() => useNowTicker({ enabled: false, intervalMs: 1000 }))
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))

    vi.setSystemTime(new Date("2026-02-03T00:00:05.000Z"))
    act(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        value: false,
      })
      document.dispatchEvent(new Event("visibilitychange"))
    })

    expect(result.current).toBe(Date.parse("2026-02-03T00:00:00.000Z"))
  })

  it("stops an active ticker when the document becomes hidden", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-03T00:00:00.000Z"))

    const { result } = renderHook(() => useNowTicker({ intervalMs: 1000 }))

    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:01.000Z"))

    act(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        value: true,
      })
      document.dispatchEvent(new Event("visibilitychange"))
    })

    act(() => {
      vi.advanceTimersByTime(5_000)
    })
    expect(result.current).toBe(Date.parse("2026-02-03T00:00:01.000Z"))

    const visibleNow = Date.now()
    act(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        value: false,
      })
      document.dispatchEvent(new Event("visibilitychange"))
    })
    expect(result.current).toBe(visibleNow)
  })

  it("keeps ticking while hidden when pauseWhenHidden is false", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-03T00:00:00.000Z"))
    Object.defineProperty(document, "hidden", {
      configurable: true,
      value: true,
    })

    const { result } = renderHook(() =>
      useNowTicker({ intervalMs: 1000, pauseWhenHidden: false })
    )

    act(() => {
      vi.advanceTimersByTime(1000)
    })

    expect(result.current).toBe(Date.parse("2026-02-03T00:00:01.000Z"))
  })
})
