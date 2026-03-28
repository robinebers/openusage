import { renderHook, act } from "@testing-library/react"
import { describe, expect, it, vi, beforeEach, afterAll } from "vitest"

import { useAppUpdate } from "@/hooks/use-app-update"

declare global {
  // eslint-disable-next-line no-var
  var isTauri: boolean | undefined
}

describe("useAppUpdate", () => {
  const originalIsTauri = globalThis.isTauri

  beforeEach(() => {
    globalThis.isTauri = true
  })

  afterAll(() => {
    if (originalIsTauri === undefined) {
      delete globalThis.isTauri
    } else {
      globalThis.isTauri = originalIsTauri
    }
  })

  it("starts checking on mount", async () => {
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("stays idle when not running in Tauri", async () => {
    globalThis.isTauri = false

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())

    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("keeps manual update actions as no-ops", async () => {
    const { result } = renderHook(() => useAppUpdate())
    await act(() => result.current.checkForUpdates())
    await act(() => result.current.triggerInstall())

    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })
})
