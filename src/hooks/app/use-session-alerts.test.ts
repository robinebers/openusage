import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { useSessionAlerts } from "@/hooks/app/use-session-alerts"
import type { PluginState } from "@/hooks/app/types"
import type { SessionAlertSettings } from "@/lib/settings"

const sendNotificationMock = vi.fn()
const requestPermissionMock = vi.fn()

vi.mock("@tauri-apps/plugin-notification", () => ({
  sendNotification: (...args: unknown[]) => sendNotificationMock(...args),
  requestPermission: () => requestPermissionMock(),
}))

vi.mock("@tauri-apps/api/core", () => ({
  isTauri: () => true,
}))

function createPluginState(resetsAt: string): PluginState {
  return {
    data: {
      providerId: "claude",
      displayName: "Claude",
      lines: [
        {
          type: "progress",
          label: "Session",
          used: 50,
          limit: 100,
          format: { kind: "percent" },
          resetsAt,
        },
      ],
      iconUrl: "",
    },
    loading: false,
    error: null,
    lastManualRefreshAt: null,
  }
}

const defaultSettings: SessionAlertSettings = {
  enabledPluginIds: ["claude"],
  minutesBefore: 5,
  sound: "default",
  customSoundPath: null,
}

describe("useSessionAlerts", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers({ shouldAdvanceTime: true })
    requestPermissionMock.mockResolvedValue("granted")
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("does not alert when no enabled plugins", () => {
    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(new Date(Date.now() + 60_000).toISOString()) },
        sessionAlertSettings: { ...defaultSettings, enabledPluginIds: [] },
      })
    )

    vi.advanceTimersByTime(35_000)
    expect(sendNotificationMock).not.toHaveBeenCalled()
  })

  it("sends notification when reset is within lead time", async () => {
    const resetsAt = new Date(Date.now() + 3 * 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: defaultSettings,
      })
    )

    await waitFor(() => expect(requestPermissionMock).toHaveBeenCalled())
    expect(sendNotificationMock).toHaveBeenCalledTimes(1)
    expect(sendNotificationMock).toHaveBeenCalledWith({
      title: "Session Resetting Soon",
      body: "Claude — Session resets in 5 min",
    })
  })

  it("does not alert when reset is beyond lead time", () => {
    const resetsAt = new Date(Date.now() + 20 * 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: defaultSettings,
      })
    )

    vi.advanceTimersByTime(35_000)
    expect(sendNotificationMock).not.toHaveBeenCalled()
  })

  it("does not duplicate alerts for same reset", async () => {
    const resetsAt = new Date(Date.now() + 2 * 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: defaultSettings,
      })
    )

    await waitFor(() => expect(sendNotificationMock).toHaveBeenCalledTimes(1))

    vi.advanceTimersByTime(35_000)
    expect(sendNotificationMock).toHaveBeenCalledTimes(1)
  })

  it("does not alert when permission denied", async () => {
    requestPermissionMock.mockResolvedValue("denied")
    const resetsAt = new Date(Date.now() + 2 * 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: defaultSettings,
      })
    )

    vi.advanceTimersByTime(35_000)
    expect(sendNotificationMock).not.toHaveBeenCalled()
  })

  it("plays custom sound when configured", async () => {
    const playMock = vi.fn().mockResolvedValue(undefined)
    global.Audio = vi.fn(function () {
      return { play: playMock }
    }) as unknown as typeof Audio

    const resetsAt = new Date(Date.now() + 2 * 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: { ...defaultSettings, sound: "custom", customSoundPath: "/test.mp3" },
      })
    )

    await waitFor(() => expect(sendNotificationMock).toHaveBeenCalledTimes(1))
    expect(playMock).toHaveBeenCalled()
  })
})
