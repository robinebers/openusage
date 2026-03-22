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
        pluginSettings: { order: ["a", "b"], disabled: [] },
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
    expect(setPluginSettings).toHaveBeenCalledWith({ order: ["b", "a"], disabled: [] })
    expect(savePluginSettingsMock).toHaveBeenCalledWith({ order: ["b", "a"], disabled: [] })
    expect(scheduleTrayIconUpdate).toHaveBeenCalledWith("settings", 2000)
  })

  it("reorder from sidebar (nav-only subset) preserves disabled plugins in order", () => {
    const setPluginSettings = vi.fn()

    // "b" is disabled so navPlugins only contains ["a", "c"]; user drags "c" before "a"
    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: ["a", "b", "c"], disabled: ["b"] },
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleReorder(["c", "a"])
    })

    // "b" originally sat between "a" (idx 0) and "c" (idx 2).
    // After nav-reorder ["c", "a"], "b" should be re-inserted after "a" → ["c", "a", "b"].
    const expectedSettings = { order: ["c", "a", "b"], disabled: ["b"] }
    expect(setPluginSettings).toHaveBeenCalledWith(expectedSettings)
    expect(savePluginSettingsMock).toHaveBeenCalledWith(expectedSettings)
  })

  it("reorder from sidebar prepends disabled plugin that originally led the order", () => {
    const setPluginSettings = vi.fn()

    // "b" is disabled and was first; navPlugins only contains ["a", "c"]; user drags "c" before "a"
    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: ["b", "a", "c"], disabled: ["b"] },
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleReorder(["c", "a"])
    })

    // "b" originally preceded all visible IDs → should be prepended → ["b", "c", "a"].
    const expectedSettings = { order: ["b", "c", "a"], disabled: ["b"] }
    expect(setPluginSettings).toHaveBeenCalledWith(expectedSettings)
    expect(savePluginSettingsMock).toHaveBeenCalledWith(expectedSettings)
  })

  it("reorder tolerates missing saved order metadata", () => {
    const setPluginSettings = vi.fn()

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: undefined as unknown as string[], disabled: [] },
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleReorder(["c", "a"])
    })

    expect(setPluginSettings).toHaveBeenCalledWith({ order: ["c", "a"], disabled: [] })
    expect(savePluginSettingsMock).toHaveBeenCalledWith({ order: ["c", "a"], disabled: [] })
  })

  it("reorder restores the full saved order when no visible plugins are passed", () => {
    const setPluginSettings = vi.fn()

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings: { order: ["b", "a", "c"], disabled: ["b"] },
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleReorder([])
    })

    expect(setPluginSettings).toHaveBeenCalledWith({ order: ["b", "a", "c"], disabled: ["b"] })
    expect(savePluginSettingsMock).toHaveBeenCalledWith({ order: ["b", "a", "c"], disabled: ["b"] })
  })

  it("reorder tolerates order metadata disappearing during merge", () => {
    const setPluginSettings = vi.fn()
    let orderReads = 0
    const pluginSettings = {
      disabled: [],
      get order() {
        orderReads += 1
        return orderReads === 1 ? ["b", "a"] : undefined
      },
    } as unknown as { order: string[]; disabled: string[] }

    const { result } = renderHook(() =>
      useSettingsPluginActions({
        pluginSettings,
        setPluginSettings,
        setLoadingForPlugins: vi.fn(),
        setErrorForPlugins: vi.fn(),
        startBatch: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleReorder(["a"])
    })

    expect(setPluginSettings).toHaveBeenCalledWith({ order: ["b", "a"], disabled: [] })
    expect(savePluginSettingsMock).toHaveBeenCalledWith({ order: ["b", "a"], disabled: [] })
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
