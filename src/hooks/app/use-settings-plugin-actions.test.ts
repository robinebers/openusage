import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const { savePluginSettingsMock, trackMock } = vi.hoisted(() => ({
  trackMock: vi.fn(),
  savePluginSettingsMock: vi.fn(),
}))

vi.mock("@/lib/analytics", () => ({
  track: trackMock,
}))

vi.mock("@/lib/settings", () => ({
  savePluginSettings: savePluginSettingsMock,
}))

import { useSettingsPluginActions } from "@/hooks/app/use-settings-plugin-actions"

describe("useSettingsPluginActions", () => {
  beforeEach(() => {
    trackMock.mockReset()
    savePluginSettingsMock.mockReset()
    savePluginSettingsMock.mockResolvedValue(undefined)
  })

  it("reorders plugins and persists new order", () => {
    const setPluginSettings = vi.fn()
    const scheduleTrayIconUpdate = vi.fn()

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: ["a", "b"], disabled: ["b"] },
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate,
      })
    )

    act(() => {
      result.current.handleReorder(["b", "a"])
    })

    expect(trackMock).toHaveBeenCalledWith("providers_reordered", { count: 2 })
    expect(setPluginSettings).toHaveBeenCalledWith({ order: ["b", "a"], disabled: ["b"] })
    expect(savePluginSettingsMock).toHaveBeenCalledWith({ order: ["b", "a"], disabled: ["b"] })
    expect(scheduleTrayIconUpdate).toHaveBeenCalledWith("settings", 2000)
  })

  it("enables and disables plugins with correct side effects", () => {
    const setPluginSettings = vi.fn()
    const setLoadingForPlugins = vi.fn()
    const startBatch = vi.fn().mockResolvedValue(undefined)

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: ["a", "b"], disabled: ["b"] },
        setPluginSettings,
        setLoadingForPlugins,
        setErrorForPlugins: vi.fn(),
        startBatch,
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleToggle("b")
    })
    expect(trackMock).toHaveBeenCalledWith("provider_toggled", { provider_id: "b", enabled: "true" })
    expect(setLoadingForPlugins).toHaveBeenCalledWith(["b"])
    expect(startBatch).toHaveBeenCalledWith(["b"])
    expect(setPluginSettings).toHaveBeenNthCalledWith(1, { order: ["a", "b"], disabled: [] })

    act(() => {
      result.current.handleToggle("a")
    })
    expect(trackMock).toHaveBeenCalledWith("provider_toggled", { provider_id: "a", enabled: "false" })
    expect(setPluginSettings).toHaveBeenNthCalledWith(2, { order: ["a", "b"], disabled: ["b", "a"] })
  })

  it("returns early when plugin settings are missing", () => {
    const setPluginSettings = vi.fn()

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: null,
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleReorder(["a"])
      result.current.handleToggle("a")
    })

    expect(setPluginSettings).not.toHaveBeenCalled()
    expect(savePluginSettingsMock).not.toHaveBeenCalled()
    expect(trackMock).not.toHaveBeenCalled()
  })

  it("logs errors when enabling probe start fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const setErrorForPlugins = vi.fn()
    const startError = new Error("probe failed")
    const saveError = new Error("save failed")

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: ["a"], disabled: ["a"] },
        setPluginSettings: vi.fn(),
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins,
        startBatch: vi.fn().mockRejectedValueOnce(startError),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    savePluginSettingsMock.mockRejectedValueOnce(saveError)

    act(() => {
      result.current.handleToggle("a")
    })

    await waitFor(() => {
      expect(setErrorForPlugins).toHaveBeenCalledWith(["a"], "Failed to start probe")
      expect(errorSpy).toHaveBeenCalledWith("Failed to start probe for enabled plugin:", startError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save plugin toggle:", saveError)
    })

    errorSpy.mockRestore()
  })
})
