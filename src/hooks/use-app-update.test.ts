import { renderHook, act } from "@testing-library/react"
import { describe, expect, it, vi, beforeEach, afterAll } from "vitest"

const { checkMock, relaunchMock } = vi.hoisted(() => ({
  checkMock: vi.fn(),
  relaunchMock: vi.fn(),
}))

vi.mock("@tauri-apps/plugin-updater", () => ({
  check: checkMock,
}))

vi.mock("@tauri-apps/plugin-process", () => ({
  relaunch: relaunchMock,
}))

import { useAppUpdate } from "@/hooks/use-app-update"

declare global {
  // eslint-disable-next-line no-var
  var isTauri: boolean | undefined
}

describe("useAppUpdate", () => {
  const originalIsTauri = globalThis.isTauri

  beforeEach(() => {
    checkMock.mockReset()
    relaunchMock.mockReset()
    // `@tauri-apps/api/core` considers `globalThis.isTauri` the runtime flag.
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
    checkMock.mockReturnValue(new Promise(() => {})) // never resolves
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "checking" })
  })

  it("auto-downloads when update is available and transitions to ready", async () => {
    const downloadMock = vi.fn(async (onEvent: (event: any) => void) => {
      onEvent({ event: "Started", data: { contentLength: 1000 } })
      onEvent({ event: "Progress", data: { chunkLength: 500 } })
      onEvent({ event: "Progress", data: { chunkLength: 500 } })
      onEvent({ event: "Finished", data: {} })
    })
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: vi.fn() })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => Promise.resolve()) // extra tick for download to complete

    expect(downloadMock).toHaveBeenCalled()
    expect(result.current.updateStatus).toEqual({ status: "ready" })
  })

  it("stays idle when check returns null", async () => {
    checkMock.mockResolvedValue(null)
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("transitions to error when check throws", async () => {
    checkMock.mockRejectedValue(new Error("network error"))
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "error", message: "Update check failed" })
  })

  it("reports indeterminate progress when content length is unknown", async () => {
    let resolveDownload: (() => void) | null = null
    const downloadMock = vi.fn((onEvent: (event: any) => void) => {
      onEvent({ event: "Started", data: { contentLength: null } })
      return new Promise<void>((resolve) => { resolveDownload = resolve })
    })
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: vi.fn() })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())

    expect(result.current.updateStatus).toEqual({ status: "downloading", progress: -1 })

    // Clean up: resolve the download
    await act(async () => { resolveDownload?.() })
  })

  it("transitions to error on download failure", async () => {
    const downloadMock = vi.fn().mockRejectedValue(new Error("download failed"))
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: vi.fn() })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => Promise.resolve()) // extra tick for error to propagate

    expect(result.current.updateStatus).toEqual({ status: "error", message: "Download failed" })
  })

  it("installs and relaunches when ready", async () => {
    const installMock = vi.fn().mockResolvedValue(undefined)
    const downloadMock = vi.fn(async (onEvent: (event: any) => void) => {
      onEvent({ event: "Finished", data: {} })
    })
    relaunchMock.mockResolvedValue(undefined)
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: installMock })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => Promise.resolve()) // wait for download to complete
    expect(result.current.updateStatus.status).toBe("ready")

    await act(() => result.current.triggerInstall())
    expect(installMock).toHaveBeenCalled()
    expect(relaunchMock).toHaveBeenCalled()
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("transitions to error on install failure", async () => {
    const installMock = vi.fn().mockRejectedValue(new Error("install failed"))
    const downloadMock = vi.fn(async (onEvent: (event: any) => void) => {
      onEvent({ event: "Finished", data: {} })
    })
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: installMock })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => Promise.resolve()) // wait for download

    await act(() => result.current.triggerInstall())
    expect(result.current.updateStatus).toEqual({ status: "error", message: "Install failed" })
  })

  it("does not update state after unmount during check", async () => {
    const resolveRef: { current: ((val: any) => void) | null } = { current: null }
    checkMock.mockReturnValue(new Promise((resolve) => { resolveRef.current = resolve }))

    const { result, unmount } = renderHook(() => useAppUpdate())
    const statusAtUnmount = result.current.updateStatus
    unmount()
    resolveRef.current?.({ version: "1.0.0", download: vi.fn(), install: vi.fn() })
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual(statusAtUnmount)
  })

  it("does not trigger install when not in ready state", async () => {
    checkMock.mockResolvedValue(null)
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())

    await act(() => result.current.triggerInstall())
    // Still idle, install ignored
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("prevents concurrent install attempts", async () => {
    let resolveInstall: (() => void) | null = null
    const installMock = vi.fn(() => new Promise<void>((resolve) => { resolveInstall = resolve }))
    const downloadMock = vi.fn(async (onEvent: (event: any) => void) => {
      onEvent({ event: "Finished", data: {} })
    })
    relaunchMock.mockResolvedValue(undefined)
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: installMock })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => Promise.resolve()) // wait for download

    act(() => { void result.current.triggerInstall() })
    act(() => { void result.current.triggerInstall() })
    await act(() => Promise.resolve())

    expect(result.current.updateStatus).toEqual({ status: "installing" })
    expect(installMock).toHaveBeenCalledTimes(1)

    await act(async () => { resolveInstall?.() })
  })
})
