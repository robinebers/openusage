import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const {
  trackMock,
  saveDisplayModeMock,
  saveResetTimerDisplayModeMock,
  saveShowAccountIdentityMock,
  saveThemeModeMock,
} = vi.hoisted(() => ({
  trackMock: vi.fn(),
  saveThemeModeMock: vi.fn(),
  saveDisplayModeMock: vi.fn(),
  saveResetTimerDisplayModeMock: vi.fn(),
  saveShowAccountIdentityMock: vi.fn(),
}))

vi.mock("@/lib/analytics", () => ({
  track: trackMock,
}))

vi.mock("@/lib/settings", () => ({
  saveThemeMode: saveThemeModeMock,
  saveDisplayMode: saveDisplayModeMock,
  saveResetTimerDisplayMode: saveResetTimerDisplayModeMock,
  saveShowAccountIdentity: saveShowAccountIdentityMock,
}))

import { useSettingsDisplayActions } from "@/hooks/app/use-settings-display-actions"

describe("useSettingsDisplayActions", () => {
  beforeEach(() => {
    trackMock.mockReset()
    saveThemeModeMock.mockReset()
    saveDisplayModeMock.mockReset()
    saveResetTimerDisplayModeMock.mockReset()
    saveShowAccountIdentityMock.mockReset()
    saveThemeModeMock.mockResolvedValue(undefined)
    saveDisplayModeMock.mockResolvedValue(undefined)
    saveResetTimerDisplayModeMock.mockResolvedValue(undefined)
    saveShowAccountIdentityMock.mockResolvedValue(undefined)
  })

  it("tracks and applies display-related setting changes", () => {
    const setThemeMode = vi.fn()
    const setDisplayMode = vi.fn()
    const setResetTimerDisplayMode = vi.fn()
    const setShowAccountIdentity = vi.fn()
    const scheduleTrayIconUpdate = vi.fn()

    const { result } = renderHook(() =>
      useSettingsDisplayActions({
        setThemeMode,
        setDisplayMode,
        resetTimerDisplayMode: "relative",
        setResetTimerDisplayMode,
        setShowAccountIdentity,
        scheduleTrayIconUpdate,
      })
    )

    act(() => {
      result.current.handleThemeModeChange("dark")
      result.current.handleDisplayModeChange("used")
      result.current.handleResetTimerDisplayModeChange("absolute")
      result.current.handleShowAccountIdentityChange(false)
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
    expect(setShowAccountIdentity).toHaveBeenCalledWith(false)
    expect(scheduleTrayIconUpdate).toHaveBeenCalledWith("settings", 0)

    expect(saveThemeModeMock).toHaveBeenCalledWith("dark")
    expect(saveDisplayModeMock).toHaveBeenCalledWith("used")
    expect(saveResetTimerDisplayModeMock).toHaveBeenCalledWith("absolute")
    expect(saveShowAccountIdentityMock).toHaveBeenCalledWith(false)
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
          setShowAccountIdentity: vi.fn(),
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
    const accountError = new Error("account failed")
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    saveThemeModeMock.mockRejectedValueOnce(themeError)
    saveDisplayModeMock.mockRejectedValueOnce(displayError)
    saveResetTimerDisplayModeMock.mockRejectedValueOnce(resetError)
    saveShowAccountIdentityMock.mockRejectedValueOnce(accountError)

    const { result } = renderHook(() =>
      useSettingsDisplayActions({
        setThemeMode: vi.fn(),
        setDisplayMode: vi.fn(),
        resetTimerDisplayMode: "relative",
        setResetTimerDisplayMode: vi.fn(),
        setShowAccountIdentity: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleThemeModeChange("light")
      result.current.handleDisplayModeChange("left")
      result.current.handleResetTimerDisplayModeChange("relative")
      result.current.handleShowAccountIdentityChange(true)
    })

    await waitFor(() => {
      expect(errorSpy).toHaveBeenCalledWith("Failed to save theme mode:", themeError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save display mode:", displayError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save reset timer display mode:", resetError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save account identity visibility:", accountError)
    })

    errorSpy.mockRestore()
  })
})
