import { beforeEach, describe, expect, it, vi, afterEach } from "vitest"

const state = vi.hoisted(() => ({
  invokeMock: vi.fn(),
  isTauriMock: vi.fn(() => true),
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: state.invokeMock,
  isTauri: state.isTauriMock,
}))

describe("analytics track", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-02-12T12:00:00.000Z"))
    vi.resetModules()
    state.invokeMock.mockReset()
    state.isTauriMock.mockReset()
    state.isTauriMock.mockReturnValue(true)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("does nothing when not running in tauri", async () => {
    state.isTauriMock.mockReturnValue(false)
    const { track } = await import("./analytics")

    track("provider_fetch_error", { provider_id: "codex", error: "network" })

    expect(state.invokeMock).not.toHaveBeenCalled()
  })

  it("deduplicates provider_fetch_error for 60 minutes", async () => {
    const { track } = await import("./analytics")

    track("provider_fetch_error", { provider_id: "codex", error: "network" })
    vi.advanceTimersByTime(59 * 60 * 1000)
    track("provider_fetch_error", { provider_id: "codex", error: "network" })

    expect(state.invokeMock).toHaveBeenCalledTimes(1)
    expect(state.invokeMock).toHaveBeenCalledWith("plugin:aptabase|track_event", {
      name: "provider_fetch_error",
      props: { provider_id: "codex", error: "network" },
    })
  })

  it("allows provider_fetch_error again after 60 minutes", async () => {
    const { track } = await import("./analytics")

    track("provider_fetch_error", { provider_id: "codex", error: "network" })
    vi.advanceTimersByTime(60 * 60 * 1000)
    track("provider_fetch_error", { provider_id: "codex", error: "network" })

    expect(state.invokeMock).toHaveBeenCalledTimes(2)
  })

  it("does not dedupe other event types", async () => {
    const { track } = await import("./analytics")

    track("setting_changed", { setting: "theme", value: "dark" })
    track("setting_changed", { setting: "theme", value: "dark" })

    expect(state.invokeMock).toHaveBeenCalledTimes(2)
  })
})
