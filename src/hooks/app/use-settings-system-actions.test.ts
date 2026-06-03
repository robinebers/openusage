import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const {
  getEnabledPluginIdsMock,
  invokeMock,
  saveAlwaysOnTopMock,
  saveAutoUpdateIntervalMock,
  saveGlobalShortcutMock,
  saveHideDockIconMock,
  saveStartOnLoginMock,
} = vi.hoisted(() => ({
  getEnabledPluginIdsMock: vi.fn(),
  saveAlwaysOnTopMock: vi.fn(),
  saveAutoUpdateIntervalMock: vi.fn(),
  saveGlobalShortcutMock: vi.fn(),
  saveHideDockIconMock: vi.fn(),
  saveStartOnLoginMock: vi.fn(),
  invokeMock: vi.fn(),
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: invokeMock,
}))

vi.mock("@/lib/settings", () => ({
  getEnabledPluginIds: getEnabledPluginIdsMock,
  saveAlwaysOnTop: saveAlwaysOnTopMock,
  saveAutoUpdateInterval: saveAutoUpdateIntervalMock,
  saveGlobalShortcut: saveGlobalShortcutMock,
  saveHideDockIcon: saveHideDockIconMock,
  saveStartOnLogin: saveStartOnLoginMock,
}))

import { useSettingsSystemActions } from "@/hooks/app/use-settings-system-actions"

describe("useSettingsSystemActions", () => {
  beforeEach(() => {
    getEnabledPluginIdsMock.mockReset()
    saveAlwaysOnTopMock.mockReset()
    saveAutoUpdateIntervalMock.mockReset()
    saveGlobalShortcutMock.mockReset()
    saveHideDockIconMock.mockReset()
    saveStartOnLoginMock.mockReset()
    invokeMock.mockReset()

    getEnabledPluginIdsMock.mockImplementation((settings: { order: string[]; disabled: string[] }) =>
      settings.order.filter((id) => !settings.disabled.includes(id))
    )
    saveAlwaysOnTopMock.mockResolvedValue(undefined)
    saveAutoUpdateIntervalMock.mockResolvedValue(undefined)
    saveGlobalShortcutMock.mockResolvedValue(undefined)
    saveHideDockIconMock.mockResolvedValue(undefined)
    saveStartOnLoginMock.mockResolvedValue(undefined)
    invokeMock.mockResolvedValue(undefined)
  })

  it("updates auto refresh schedule when at least one plugin is enabled", () => {
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(10_000)
    const setAutoUpdateInterval = vi.fn()
    const setAutoUpdateNextAt = vi.fn()

    const { result } = renderHook(() =>
      useSettingsSystemActions({
        pluginSettings: { order: ["codex"], disabled: [] },
        setAutoUpdateInterval,
        setAutoUpdateNextAt,
        setGlobalShortcut: vi.fn(),
        setStartOnLogin: vi.fn(),
        setHideDockIcon: vi.fn(),
        setAlwaysOnTop: vi.fn(),
        applyStartOnLogin: vi.fn().mockResolvedValue(undefined),
      })
    )

    act(() => {
      result.current.handleAutoUpdateIntervalChange(15)
    })

    expect(setAutoUpdateInterval).toHaveBeenCalledWith(15)
    expect(setAutoUpdateNextAt).toHaveBeenCalledWith(910_000)
    expect(saveAutoUpdateIntervalMock).toHaveBeenCalledWith(15)
    nowSpy.mockRestore()
  })

  it("clears next refresh when no enabled plugins remain", () => {
    const setAutoUpdateNextAt = vi.fn()

    const { result } = renderHook(() =>
      useSettingsSystemActions({
        pluginSettings: { order: ["codex"], disabled: ["codex"] },
        setAutoUpdateInterval: vi.fn(),
        setAutoUpdateNextAt,
        setGlobalShortcut: vi.fn(),
        setStartOnLogin: vi.fn(),
        setHideDockIcon: vi.fn(),
        setAlwaysOnTop: vi.fn(),
        applyStartOnLogin: vi.fn().mockResolvedValue(undefined),
      })
    )

    act(() => {
      result.current.handleAutoUpdateIntervalChange(30)
    })

    expect(setAutoUpdateNextAt).toHaveBeenCalledWith(null)
  })

  it("updates shortcut and start-on-login settings", () => {
    const setGlobalShortcut = vi.fn()
    const setStartOnLogin = vi.fn()
    const setHideDockIcon = vi.fn()
    const setAlwaysOnTop = vi.fn()
    const applyStartOnLogin = vi.fn().mockResolvedValue(undefined)

    const { result } = renderHook(() =>
      useSettingsSystemActions({
        pluginSettings: null,
        setAutoUpdateInterval: vi.fn(),
        setAutoUpdateNextAt: vi.fn(),
        setGlobalShortcut,
        setStartOnLogin,
        setHideDockIcon,
        setAlwaysOnTop,
        applyStartOnLogin,
      })
    )

    act(() => {
      result.current.handleGlobalShortcutChange("CommandOrControl+Shift+O")
      result.current.handleStartOnLoginChange(true)
      result.current.handleHideDockIconChange(false)
      result.current.handleAlwaysOnTopChange(true)
    })

    expect(setGlobalShortcut).toHaveBeenCalledWith("CommandOrControl+Shift+O")
    expect(saveGlobalShortcutMock).toHaveBeenCalledWith("CommandOrControl+Shift+O")
    expect(invokeMock).toHaveBeenCalledWith("update_global_shortcut", {
      shortcut: "CommandOrControl+Shift+O",
    })

    expect(setStartOnLogin).toHaveBeenCalledWith(true)
    expect(saveStartOnLoginMock).toHaveBeenCalledWith(true)
    expect(applyStartOnLogin).toHaveBeenCalledWith(true)

    expect(setHideDockIcon).toHaveBeenCalledWith(false)
    expect(saveHideDockIconMock).toHaveBeenCalledWith(false)
    expect(invokeMock).toHaveBeenCalledWith("update_dock_icon_visibility", {
      hidden: false,
    })

    expect(setAlwaysOnTop).toHaveBeenCalledWith(true)
    expect(saveAlwaysOnTopMock).toHaveBeenCalledWith(true)
    expect(invokeMock).toHaveBeenCalledWith("update_always_on_top", {
      enabled: true,
    })
  })

  it("logs persistence/update failures", async () => {
    const autoError = new Error("auto save failed")
    const shortcutSaveError = new Error("shortcut save failed")
    const shortcutInvokeError = new Error("shortcut invoke failed")
    const startOnLoginSaveError = new Error("start on login save failed")
    const startOnLoginApplyError = new Error("start on login apply failed")
    const hideDockIconSaveError = new Error("hide dock icon save failed")
    const hideDockIconInvokeError = new Error("hide dock icon invoke failed")
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    saveAutoUpdateIntervalMock.mockRejectedValueOnce(autoError)
    saveGlobalShortcutMock.mockRejectedValueOnce(shortcutSaveError)
    invokeMock.mockRejectedValueOnce(shortcutInvokeError)
    saveStartOnLoginMock.mockRejectedValueOnce(startOnLoginSaveError)
    saveHideDockIconMock.mockRejectedValueOnce(hideDockIconSaveError)
    invokeMock.mockRejectedValueOnce(hideDockIconInvokeError)
    const applyStartOnLogin = vi.fn().mockRejectedValueOnce(startOnLoginApplyError)

    const { result } = renderHook(() =>
      useSettingsSystemActions({
        pluginSettings: null,
        setAutoUpdateInterval: vi.fn(),
        setAutoUpdateNextAt: vi.fn(),
        setGlobalShortcut: vi.fn(),
        setStartOnLogin: vi.fn(),
        setHideDockIcon: vi.fn(),
        setAlwaysOnTop: vi.fn(),
        applyStartOnLogin,
      })
    )

    act(() => {
      result.current.handleAutoUpdateIntervalChange(5)
      result.current.handleGlobalShortcutChange(null)
      result.current.handleStartOnLoginChange(false)
      result.current.handleHideDockIconChange(true)
    })

    await waitFor(() => {
      expect(errorSpy).toHaveBeenCalledWith("Failed to save auto-update interval:", autoError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save global shortcut:", shortcutSaveError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to update global shortcut:", shortcutInvokeError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save start on login:", startOnLoginSaveError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to update start on login:", startOnLoginApplyError)
      expect(errorSpy).toHaveBeenCalledWith(
        "Failed to save hide dock icon setting:",
        hideDockIconSaveError
      )
      expect(errorSpy).toHaveBeenCalledWith(
        "Failed to update dock icon visibility:",
        hideDockIconInvokeError
      )
    })

    errorSpy.mockRestore()
  })
})
