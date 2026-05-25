import { act, renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const { getEnabledPluginIdsMock } = vi.hoisted(() => ({
  getEnabledPluginIdsMock: vi.fn(),
}))

vi.mock("@/lib/settings", () => ({
  getEnabledPluginIds: getEnabledPluginIdsMock,
}))

import { useProbeAutoUpdate } from "@/hooks/app/use-probe-auto-update"

describe("useProbeAutoUpdate", () => {
  beforeEach(() => {
    getEnabledPluginIdsMock.mockReset()
    getEnabledPluginIdsMock.mockImplementation((settings: { order: string[]; disabled: string[] }) =>
      settings.order.filter((id) => !settings.disabled.includes(id))
    )
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("keeps auto-update cleared when plugin settings are missing", () => {
    const { result } = renderHook(() =>
      useProbeAutoUpdate({
        pluginSettings: null,
        autoUpdateInterval: 15,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        isPluginLoading: vi.fn(() => false),
        startBatch: vi.fn(),
      })
    )

    act(() => {
      result.current.resetAutoUpdateSchedule()
    })

    expect(result.current.autoUpdateNextAt).toBeNull()
  })

  it("resets the schedule when enabled plugins are present", () => {
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(10_000)

    const { result } = renderHook(() =>
      useProbeAutoUpdate({
        pluginSettings: { order: ["codex"], disabled: [] },
        autoUpdateInterval: 15,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        isPluginLoading: vi.fn(() => false),
        startBatch: vi.fn(),
      })
    )

    act(() => {
      result.current.resetAutoUpdateSchedule()
    })

    expect(result.current.autoUpdateNextAt).toBe(910_000)
    nowSpy.mockRestore()
  })

  it("skips providers that are still loading when auto-update fires", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(10_000)

    const setLoadingForPlugins = vi.fn()
    const setErrorForPlugins = vi.fn()
    const startBatch = vi.fn().mockResolvedValue(["idle"])
    const isPluginLoading = vi.fn((id: string) => id === "slow")

    renderHook(() =>
      useProbeAutoUpdate({
        pluginSettings: { order: ["slow", "idle"], disabled: [] },
        autoUpdateInterval: 15,
        setLoadingForPlugins,
        setErrorForPlugins,
        isPluginLoading,
        startBatch,
      })
    )

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15 * 60_000)
    })

    expect(isPluginLoading).toHaveBeenCalledWith("slow")
    expect(isPluginLoading).toHaveBeenCalledWith("idle")
    expect(setLoadingForPlugins).toHaveBeenCalledWith(["idle"])
    expect(startBatch).toHaveBeenCalledWith(["idle"])
    expect(setErrorForPlugins).not.toHaveBeenCalled()
  })

  it("does not start an auto-update batch when every provider is still loading", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(10_000)

    const setLoadingForPlugins = vi.fn()
    const setErrorForPlugins = vi.fn()
    const startBatch = vi.fn()

    const { result } = renderHook(() =>
      useProbeAutoUpdate({
        pluginSettings: { order: ["slow"], disabled: [] },
        autoUpdateInterval: 15,
        setLoadingForPlugins,
        setErrorForPlugins,
        isPluginLoading: vi.fn(() => true),
        startBatch,
      })
    )

    expect(result.current.autoUpdateNextAt).toBe(910_000)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15 * 60_000)
    })

    expect(result.current.autoUpdateNextAt).toBe(1_810_000)
    expect(setLoadingForPlugins).not.toHaveBeenCalled()
    expect(startBatch).not.toHaveBeenCalled()
    expect(setErrorForPlugins).not.toHaveBeenCalled()
  })
})
