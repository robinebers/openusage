import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const {
  currentMonitorMock,
  getCurrentWindowMock,
  invokeMock,
  isTauriMock,
  listenMock,
} = vi.hoisted(() => ({
  invokeMock: vi.fn(),
  isTauriMock: vi.fn(),
  listenMock: vi.fn(),
  getCurrentWindowMock: vi.fn(),
  currentMonitorMock: vi.fn(),
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

    isTauriMock.mockReturnValue(true)
    invokeMock.mockResolvedValue(undefined)
    listenMock.mockResolvedValue(vi.fn())
    currentMonitorMock.mockResolvedValue(null)
    getCurrentWindowMock.mockReturnValue({
      setSize: vi.fn().mockResolvedValue(undefined),
      outerSize: vi.fn().mockResolvedValue({ width: 0, height: 0 }),
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
        displayPlugins: [],
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
        displayPlugins: [],
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
        displayPlugins: [],
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

  it("switches views with Cmd+Arrow navigation", () => {
    const setActiveView = vi.fn()

    const firstHook = renderHook(() =>
      usePanel({
        activeView: "home",
        setActiveView,
        showAbout: false,
        setShowAbout: vi.fn(),
        displayPlugins: [
          {
            meta: { id: "a" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
          {
            meta: { id: "b" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
        ],
      })
    )

    act(() => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", metaKey: true }))
    })

    expect(setActiveView).toHaveBeenCalledWith("a")

    firstHook.unmount()
    setActiveView.mockClear()

    const secondHook = renderHook(() =>
      usePanel({
        activeView: "b",
        setActiveView,
        showAbout: false,
        setShowAbout: vi.fn(),
        displayPlugins: [
          {
            meta: { id: "a" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
          {
            meta: { id: "b" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
        ],
      })
    )

    act(() => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", metaKey: true }))
    })

    expect(setActiveView).toHaveBeenCalledWith("home")
    secondHook.unmount()
  })

  it("ignores Cmd+Arrow navigation from editable targets", () => {
    const setActiveView = vi.fn()
    const { result } = renderHook(() =>
      usePanel({
        activeView: "a",
        setActiveView,
        showAbout: false,
        setShowAbout: vi.fn(),
        displayPlugins: [
          {
            meta: { id: "a" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
        ],
      })
    )

    const textbox = document.createElement("div")
    textbox.setAttribute("role", "textbox")
    document.body.appendChild(textbox)

    act(() => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", metaKey: true, bubbles: true }))
    })

    expect(setActiveView).toHaveBeenCalledWith("home")

    setActiveView.mockClear()

    act(() => {
      textbox.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", metaKey: true, bubbles: true }))
    })

    expect(setActiveView).not.toHaveBeenCalled()
    document.body.removeChild(textbox)
    expect(result.current.containerRef.current).toBeNull()
  })

  it("skips settings when navigating with Cmd+Arrow", () => {
    const setActiveView = vi.fn()

    renderHook(() =>
      usePanel({
        activeView: "settings",
        setActiveView,
        showAbout: false,
        setShowAbout: vi.fn(),
        displayPlugins: [
          {
            meta: { id: "a" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
          {
            meta: { id: "b" },
            data: null,
            loading: false,
            error: null,
            lastManualRefreshAt: null,
          } as any,
        ],
      })
    )

    act(() => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", metaKey: true }))
    })

    expect(setActiveView).toHaveBeenCalledWith("home")

    setActiveView.mockClear()

    act(() => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", metaKey: true }))
    })

    expect(setActiveView).toHaveBeenCalledWith("b")
  })

  it("focuses the panel container when the window regains focus", () => {
    const requestAnimationFrameSpy = vi
      .spyOn(window, "requestAnimationFrame")
      .mockImplementation((callback: FrameRequestCallback) => {
        callback(0)
        return 0
      })

    const { result } = renderHook(() =>
      usePanel({
        activeView: "home",
        setActiveView: vi.fn(),
        showAbout: false,
        setShowAbout: vi.fn(),
        displayPlugins: [],
      })
    )

    const container = document.createElement("div")
    container.tabIndex = -1
    document.body.appendChild(container)

    act(() => {
      result.current.containerRef.current = container
    })

    act(() => {
      window.dispatchEvent(new Event("focus"))
    })

    expect(container).toHaveFocus()

    document.body.removeChild(container)
    requestAnimationFrameSpy.mockRestore()
  })
})
