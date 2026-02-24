import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const {
  trackMock,
  saveDisplayModeMock,
  saveResetTimerDisplayModeMock,
  saveThemeModeMock,
} = vi.hoisted(() => ({
  trackMock: vi.fn(),
  saveThemeModeMock: vi.fn(),
  saveDisplayModeMock: vi.fn(),
  saveResetTimerDisplayModeMock: vi.fn(),
}))

vi.mock("@/lib/analytics", () => ({
  track: trackMock,
}))

vi.mock("@/lib/settings", () => ({
  saveThemeMode: saveThemeModeMock,
  saveDisplayMode: saveDisplayModeMock,
  saveResetTimerDisplayMode: saveResetTimerDisplayModeMock,
}))

import { useSettingsDisplayActions } from "@/hooks/app/use-settings-display-actions"

describe("useSettingsDisplayActions", () => {
  beforeEach(() => {
    trackMock.mockReset()
    saveThemeModeMock.mockReset()
    saveDisplayModeMock.mockReset()
    saveResetTimerDisplayModeMock.mockReset()
    saveThemeModeMock.mockResolvedValue(undefined)
    saveDisplayModeMock.mockResolvedValue(undefined)
    saveResetTimerDisplayModeMock.mockResolvedValue(undefined)
  })

  it("tracks and applies display-related setting changes", () => {
    const setThemeMode = vi.fn()
    const setDisplayMode = vi.fn()
    const setResetTimerDisplayMode = vi.fn()
    const scheduleTrayIconUpdate = vi.fn()

    const { result } = renderHook(() =>
      useSettingsDisplayActions({
        setThemeMode,
        setDisplayMode,
        resetTimerDisplayMode: "relative",
        setResetTimerDisplayMode,
        scheduleTrayIconUpdate,
      })
    )

    act(() => {
      result.current.handleThemeModeChange("dark")
      result.current.handleDisplayModeChange("used")
      result.current.handleResetTimerDisplayModeChange("absolute")
    })

    expect(trackMock).toHaveBeenCalledWith("setting_changed", { setting: "theme", value: "dark" })
    expect(trackMock).toHaveBeenCalledWith("setting_changed", {
      setting: "display_mode",
      value: "used",
    })
    expect(trackMock).toHaveBeenCalledWith("setting_changed", {
      setting: "reset_timer_display_mode",
      value: "absolute",
    })

    expect(setThemeMode).toHaveBeenCalledWith("dark")
    expect(setDisplayMode).toHaveBeenCalledWith("used")
    expect(setResetTimerDisplayMode).toHaveBeenCalledWith("absolute")
    expect(scheduleTrayIconUpdate).toHaveBeenCalledWith("settings", 0)

    expect(saveThemeModeMock).toHaveBeenCalledWith("dark")
    expect(saveDisplayModeMock).toHaveBeenCalledWith("used")
    expect(saveResetTimerDisplayModeMock).toHaveBeenCalledWith("absolute")
  })

  it("toggles reset timer mode in both directions", () => {
    const setResetTimerDisplayMode = vi.fn()

    const { result, rerender } = renderHook(
      ({ mode }: { mode: "relative" | "absolute" }) =>
        useSettingsDisplayActions({
          setThemeMode: vi.fn(),
          setDisplayMode: vi.fn(),
          resetTimerDisplayMode: mode,
          setResetTimerDisplayMode,
          scheduleTrayIconUpdate: vi.fn(),
        }),
      { initialProps: { mode: "relative" as const } }
    )

    act(() => {
      result.current.handleResetTimerDisplayModeToggle()
    })
    expect(setResetTimerDisplayMode).toHaveBeenCalledWith("absolute")

    rerender({ mode: "absolute" })
    act(() => {
      result.current.handleResetTimerDisplayModeToggle()
    })
    expect(setResetTimerDisplayMode).toHaveBeenCalledWith("relative")
  })

  it("logs persistence failures", async () => {
    const themeError = new Error("theme failed")
    const displayError = new Error("display failed")
    const resetError = new Error("reset failed")
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    saveThemeModeMock.mockRejectedValueOnce(themeError)
    saveDisplayModeMock.mockRejectedValueOnce(displayError)
    saveResetTimerDisplayModeMock.mockRejectedValueOnce(resetError)

    const { result } = renderHook(() =>
      useSettingsDisplayActions({
        setThemeMode: vi.fn(),
        setDisplayMode: vi.fn(),
        resetTimerDisplayMode: "relative",
        setResetTimerDisplayMode: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleThemeModeChange("light")
      result.current.handleDisplayModeChange("left")
      result.current.handleResetTimerDisplayModeChange("relative")
    })

    await waitFor(() => {
      expect(errorSpy).toHaveBeenCalledWith("Failed to save theme mode:", themeError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save display mode:", displayError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save reset timer display mode:", resetError)
    })

    errorSpy.mockRestore()
  })
})
