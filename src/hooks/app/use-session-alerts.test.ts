import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { useSessionAlerts } from "@/hooks/app/use-session-alerts"
import type { PluginState } from "@/hooks/app/types"
import type { SessionAlertSettings } from "@/lib/settings"

const sendNotificationMock = vi.fn()
const requestPermissionMock = vi.fn()
const invokeMock = vi.fn()

vi.mock("@tauri-apps/plugin-notification", () => ({
  sendNotification: (...args: unknown[]) => sendNotificationMock(...args),
  requestPermission: () => requestPermissionMock(),
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
  isTauri: () => true,
}))

function createPluginState(resetsAt: string, providerId = "claude", displayName = "Claude", label = "Session"): PluginState {
  return {
    data: {
      providerId,
      displayName,
      lines: [
        {
          type: "progress",
          label,
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
  enabledAlerts: ["claude:session"],
  sound: "system",
}

describe("useSessionAlerts", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers({ shouldAdvanceTime: true })
    invokeMock.mockResolvedValue(undefined)
    requestPermissionMock.mockResolvedValue("granted")
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("does not alert when no enabled plugins", () => {
    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(new Date(Date.now() + 60_000).toISOString()) },
        sessionAlertSettings: { ...defaultSettings, enabledAlerts: [] },
      })
    )

    vi.advanceTimersByTime(35_000)
    expect(sendNotificationMock).not.toHaveBeenCalled()
  })

  it("sends notification when reset time has passed", async () => {
    const resetsAt = new Date(Date.now() - 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: defaultSettings,
      })
    )

    await waitFor(() => expect(requestPermissionMock).toHaveBeenCalled())
    expect(sendNotificationMock).toHaveBeenCalledTimes(1)
    expect(sendNotificationMock).toHaveBeenCalledWith({
      title: "Limit Refreshed",
      body: "Claude session refreshed.",
    })
  })

  it("does not alert before reset time", () => {
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
    const resetsAt = new Date(Date.now() - 60_000).toISOString()

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

  it("queues bundled sound when configured", async () => {
    const resetsAt = new Date(Date.now() - 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { codex: createPluginState(resetsAt, "codex", "Codex") },
        sessionAlertSettings: { ...defaultSettings, enabledAlerts: ["codex:session"], sound: "bundled" },
      })
    )

    await waitFor(() => expect(sendNotificationMock).toHaveBeenCalledTimes(1))
    expect(invokeMock).toHaveBeenCalledWith("play_notification_sound", {
      fileName: "codex-session.mp3",
    })
  })

  it("uses the system notification sound by default", async () => {
    const resetsAt = new Date(Date.now() - 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { claude: createPluginState(resetsAt) },
        sessionAlertSettings: defaultSettings,
      })
    )

    await waitFor(() => expect(sendNotificationMock).toHaveBeenCalledTimes(1))
    expect(invokeMock).not.toHaveBeenCalled()
  })

  it("does not play a bundled sound when the provider audio is missing", async () => {
    const resetsAt = new Date(Date.now() - 60_000).toISOString()

    renderHook(() =>
      useSessionAlerts({
        pluginStates: { amp: createPluginState(resetsAt, "amp", "Amp", "Bonus") },
        sessionAlertSettings: { ...defaultSettings, enabledAlerts: ["amp:bonus"], sound: "bundled" },
      })
    )

    await waitFor(() => expect(sendNotificationMock).toHaveBeenCalledTimes(1))
    expect(invokeMock).not.toHaveBeenCalled()
  })
})
