import { act, render, renderHook, waitFor } from "@testing-library/react"
import { createElement } from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const {
  currentMonitorMock,
  getCurrentWindowMock,
  invokeMock,
  isTauriMock,
  listenMock,
  onMovedMock,
  onScaleChangedMock,
} = vi.hoisted(() => ({
  invokeMock: vi.fn(),
  isTauriMock: vi.fn(),
  listenMock: vi.fn(),
  getCurrentWindowMock: vi.fn(),
  currentMonitorMock: vi.fn(),
  onMovedMock: vi.fn(),
  onScaleChangedMock: vi.fn(),
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: invokeMock,
  isTauri: isTauriMock,
}))

vi.mock("@tauri-apps/api/event", () => ({
  listen: listenMock,
}))

vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: getCurrentWindowMock,
  currentMonitor: currentMonitorMock,
  PhysicalSize: class PhysicalSize {
    width: number
    height: number

    constructor(width: number, height: number) {
      this.width = width
      this.height = height
    }
  },
}))

import { usePanel } from "@/hooks/app/use-panel"

describe("usePanel", () => {
  beforeEach(() => {
    invokeMock.mockReset()
    isTauriMock.mockReset()
    listenMock.mockReset()
    getCurrentWindowMock.mockReset()
    currentMonitorMock.mockReset()
    onMovedMock.mockReset()
    onScaleChangedMock.mockReset()

    isTauriMock.mockReturnValue(true)
    invokeMock.mockResolvedValue(undefined)
    listenMock.mockResolvedValue(vi.fn())
    currentMonitorMock.mockResolvedValue(null)
    onMovedMock.mockResolvedValue(vi.fn())
    onScaleChangedMock.mockResolvedValue(vi.fn())
    getCurrentWindowMock.mockReturnValue({
      setSize: vi.fn().mockResolvedValue(undefined),
      onMoved: onMovedMock,
      onScaleChanged: onScaleChangedMock,
    })
  })

  it("handles tray show-about event", async () => {
    const setShowAbout = vi.fn()
    const callbacks = new Map<string, (event: { payload: unknown }) => void>()

    listenMock.mockImplementation(async (event: string, callback: (event: { payload: unknown }) => void) => {
      callbacks.set(event, callback)
      return vi.fn()
    })

    renderHook(() =>
      usePanel({
        activeView: "home",
        setActiveView: vi.fn(),
        showAbout: false,
        setShowAbout,
      })
    )

    await waitFor(() => {
      expect(listenMock).toHaveBeenCalledTimes(2)
    })

    act(() => {
      callbacks.get("tray:show-about")?.({ payload: null })
    })

    expect(setShowAbout).toHaveBeenCalledWith(true)
  })

  it("cleans first listener if hook unmounts before setup resolves", async () => {
    const unlistenNavigate = vi.fn()
    let resolveNavigate: ((value: () => void) => void) | null = null

    listenMock
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveNavigate = resolve
          })
      )
      .mockResolvedValue(vi.fn())

    const { unmount } = renderHook(() =>
      usePanel({
        activeView: "home",
        setActiveView: vi.fn(),
        showAbout: false,
        setShowAbout: vi.fn(),
      })
    )

    unmount()
    resolveNavigate?.(unlistenNavigate)

    await waitFor(() => {
      expect(unlistenNavigate).toHaveBeenCalledTimes(1)
    })
  })

  it("cleans second listener if hook unmounts between listener registrations", async () => {
    const unlistenNavigate = vi.fn()
    const unlistenShowAbout = vi.fn()
    let resolveShowAbout: ((value: () => void) => void) | null = null

    listenMock
      .mockResolvedValueOnce(unlistenNavigate)
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveShowAbout = resolve
          })
      )

    const { unmount } = renderHook(() =>
      usePanel({
        activeView: "home",
        setActiveView: vi.fn(),
        showAbout: false,
        setShowAbout: vi.fn(),
      })
    )

    await waitFor(() => {
      expect(listenMock).toHaveBeenCalledTimes(2)
    })

    unmount()
    resolveShowAbout?.(unlistenShowAbout)

    await waitFor(() => {
      expect(unlistenShowAbout).toHaveBeenCalledTimes(1)
    })
  })

  it("recalculates panel sizing when the window scale changes", async () => {
    const setSize = vi.fn().mockResolvedValue(undefined)
    let scaleChangedHandler: (() => void) | null = null

    currentMonitorMock.mockResolvedValue({ size: { height: 1000 } })
    onScaleChangedMock.mockImplementation(async (handler: () => void) => {
      scaleChangedHandler = handler
      return vi.fn()
    })
    getCurrentWindowMock.mockReturnValue({
      setSize,
      onMoved: onMovedMock,
      onScaleChanged: onScaleChangedMock,
    })

    function Harness() {
      const { containerRef, scrollRef } = usePanel({
        activeView: "home",
        setActiveView: vi.fn(),
        showAbout: false,
        setShowAbout: vi.fn(),
      })

      return createElement("div", { ref: containerRef }, createElement("div", { ref: scrollRef }))
    }

    render(createElement(Harness))

    await waitFor(() => {
      expect(setSize).toHaveBeenCalledTimes(1)
    })

    act(() => {
      scaleChangedHandler?.()
    })

    await waitFor(() => {
      expect(currentMonitorMock).toHaveBeenCalledTimes(2)
    })
  })
})
