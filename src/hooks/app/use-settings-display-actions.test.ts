import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const {
  saveDisplayModeMock,
  saveResetTimerDisplayModeMock,
  saveThemeModeMock,
  saveTimeFormatModeMock,
} = vi.hoisted(() => ({
  saveThemeModeMock: vi.fn(),
  saveDisplayModeMock: vi.fn(),
  saveResetTimerDisplayModeMock: vi.fn(),
  saveTimeFormatModeMock: vi.fn(),
}))

vi.mock("@/lib/settings", () => ({
  saveThemeMode: saveThemeModeMock,
  saveDisplayMode: saveDisplayModeMock,
  saveResetTimerDisplayMode: saveResetTimerDisplayModeMock,
  saveTimeFormatMode: saveTimeFormatModeMock,
}))

import { useSettingsDisplayActions } from "@/hooks/app/use-settings-display-actions"

describe("useSettingsDisplayActions", () => {
  beforeEach(() => {
    saveThemeModeMock.mockReset()
    saveDisplayModeMock.mockReset()
    saveResetTimerDisplayModeMock.mockReset()
    saveTimeFormatModeMock.mockReset()
    saveThemeModeMock.mockResolvedValue(undefined)
    saveDisplayModeMock.mockResolvedValue(undefined)
    saveResetTimerDisplayModeMock.mockResolvedValue(undefined)
    saveTimeFormatModeMock.mockResolvedValue(undefined)
  })

  it("applies display-related setting changes", () => {
    const setThemeMode = vi.fn()
    const setDisplayMode = vi.fn()
    const setResetTimerDisplayMode = vi.fn()
    const setTimeFormatMode = vi.fn()
    const scheduleTrayIconUpdate = vi.fn()

    const { result } = renderHook(() =>
      useSettingsDisplayActions({
        setThemeMode,
        setDisplayMode,
        resetTimerDisplayMode: "relative",
        setResetTimerDisplayMode,
        setTimeFormatMode,
        setMenubarIconStyle: vi.fn(),
        scheduleTrayIconUpdate,
      })
    )

    act(() => {
      result.current.handleThemeModeChange("dark")
      result.current.handleDisplayModeChange("used")
      result.current.handleResetTimerDisplayModeChange("absolute")
      result.current.handleTimeFormatModeChange("24h")
    })

    expect(setThemeMode).toHaveBeenCalledWith("dark")
    expect(setDisplayMode).toHaveBeenCalledWith("used")
    expect(setResetTimerDisplayMode).toHaveBeenCalledWith("absolute")
    expect(setTimeFormatMode).toHaveBeenCalledWith("24h")
    expect(scheduleTrayIconUpdate).toHaveBeenCalledWith("settings", 0)

    expect(saveThemeModeMock).toHaveBeenCalledWith("dark")
    expect(saveDisplayModeMock).toHaveBeenCalledWith("used")
    expect(saveResetTimerDisplayModeMock).toHaveBeenCalledWith("absolute")
    expect(saveTimeFormatModeMock).toHaveBeenCalledWith("24h")
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
          setTimeFormatMode: vi.fn(),
          setMenubarIconStyle: vi.fn(),
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

    const timeFormatError = new Error("time format failed")
    saveTimeFormatModeMock.mockRejectedValueOnce(timeFormatError)

    const { result } = renderHook(() =>
      useSettingsDisplayActions({
        setThemeMode: vi.fn(),
        setDisplayMode: vi.fn(),
        resetTimerDisplayMode: "relative",
        setResetTimerDisplayMode: vi.fn(),
        setTimeFormatMode: vi.fn(),
        setMenubarIconStyle: vi.fn(),
        scheduleTrayIconUpdate: vi.fn(),
      })
    )

    act(() => {
      result.current.handleThemeModeChange("light")
      result.current.handleDisplayModeChange("left")
      result.current.handleResetTimerDisplayModeChange("relative")
      result.current.handleTimeFormatModeChange("12h")
    })

    await waitFor(() => {
      expect(errorSpy).toHaveBeenCalledWith("Failed to save theme mode:", themeError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save display mode:", displayError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save reset timer display mode:", resetError)
      expect(errorSpy).toHaveBeenCalledWith("Failed to save time format mode:", timeFormatError)
    })

    errorSpy.mockRestore()
  })
})
