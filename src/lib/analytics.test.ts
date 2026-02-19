import { beforeEach, describe, expect, it, vi } from "vitest"

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
    vi.resetModules()
    state.invokeMock.mockReset()
    state.isTauriMock.mockReset()
    state.isTauriMock.mockReturnValue(true)
  })

  it("does nothing when not running in tauri", async () => {
    state.isTauriMock.mockReturnValue(false)
    const { track } = await import("./analytics")

    track("setting_changed", { setting: "theme", value: "dark" })

    expect(state.invokeMock).not.toHaveBeenCalled()
  })

  it("tracks all events when running in tauri", async () => {
    const { track } = await import("./analytics")

    track("setting_changed", { setting: "theme", value: "dark" })
    track("setting_changed", { setting: "theme", value: "dark" })

    expect(state.invokeMock).toHaveBeenCalledTimes(2)
  })
})
