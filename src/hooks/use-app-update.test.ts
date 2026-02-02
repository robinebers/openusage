import { renderHook, act } from "@testing-library/react"
import { describe, expect, it, vi, beforeEach } from "vitest"

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

describe("useAppUpdate", () => {
  beforeEach(() => {
    checkMock.mockReset()
    relaunchMock.mockReset()
  })

  it("starts in idle state", () => {
    checkMock.mockReturnValue(new Promise(() => {})) // never resolves
    const { result } = renderHook(() => useAppUpdate())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("transitions to available when check finds an update", async () => {
    checkMock.mockResolvedValue({ version: "1.0.0", download: vi.fn(), install: vi.fn() })
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "available", version: "1.0.0" })
  })

  it("stays idle when check returns null", async () => {
    checkMock.mockResolvedValue(null)
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("stays idle when check throws", async () => {
    checkMock.mockRejectedValue(new Error("network error"))
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("tracks download progress through to ready", async () => {
    const downloadMock = vi.fn(async (onEvent: (event: any) => void) => {
      onEvent({ event: "Started", data: { contentLength: 1000 } })
      onEvent({ event: "Progress", data: { chunkLength: 500 } })
      onEvent({ event: "Progress", data: { chunkLength: 500 } })
      onEvent({ event: "Finished", data: {} })
    })
    const installMock = vi.fn()
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: installMock })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    expect(result.current.updateStatus.status).toBe("available")

    await act(() => result.current.triggerDownload())
    expect(result.current.updateStatus).toEqual({ status: "ready" })
  })

  it("reports indeterminate progress when content length is unknown", async () => {
    let resolveDownload: (() => void) | null = null
    const downloadMock = vi.fn((onEvent: (event: any) => void) => {
      onEvent({ event: "Started", data: { contentLength: null } })
      // Return a promise that doesn't resolve until we say so
      return new Promise<void>((resolve) => { resolveDownload = resolve })
    })
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: vi.fn() })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())

    // Start download without awaiting — it will hang until resolveDownload is called
    act(() => { void result.current.triggerDownload() })
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

    await act(() => result.current.triggerDownload())
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
    await act(() => result.current.triggerDownload())
    expect(result.current.updateStatus.status).toBe("ready")

    await act(() => result.current.triggerInstall())
    expect(installMock).toHaveBeenCalled()
    expect(relaunchMock).toHaveBeenCalled()
  })

  it("transitions to error on install failure", async () => {
    const installMock = vi.fn().mockRejectedValue(new Error("install failed"))
    const downloadMock = vi.fn(async (onEvent: (event: any) => void) => {
      onEvent({ event: "Finished", data: {} })
    })
    checkMock.mockResolvedValue({ version: "1.0.0", download: downloadMock, install: installMock })

    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())
    await act(() => result.current.triggerDownload())

    await act(() => result.current.triggerInstall())
    expect(result.current.updateStatus).toEqual({ status: "error", message: "Install failed" })
  })

  it("does not update state after unmount during check", async () => {
    const resolveRef: { current: ((val: any) => void) | null } = { current: null }
    checkMock.mockReturnValue(new Promise((resolve) => { resolveRef.current = resolve }))

    const { result, unmount } = renderHook(() => useAppUpdate())
    unmount()
    resolveRef.current?.({ version: "1.0.0", download: vi.fn(), install: vi.fn() })
    await act(() => Promise.resolve())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("does not trigger download when not in available state", async () => {
    checkMock.mockResolvedValue(null)
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())

    await act(() => result.current.triggerDownload())
    expect(result.current.updateStatus).toEqual({ status: "idle" })
  })

  it("does not trigger install when not in ready state", async () => {
    checkMock.mockResolvedValue({ version: "1.0.0", download: vi.fn(), install: vi.fn() })
    const { result } = renderHook(() => useAppUpdate())
    await act(() => Promise.resolve())

    await act(() => result.current.triggerInstall())
    // Still available, not changed
    expect(result.current.updateStatus).toEqual({ status: "available", version: "1.0.0" })
  })
})
