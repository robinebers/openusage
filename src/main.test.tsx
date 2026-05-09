import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const renderMock = vi.fn()
const createRootMock = vi.fn(() => ({ render: renderMock }))
const { logErrorMock, logWarnMock } = vi.hoisted(() => ({
  logErrorMock: vi.fn(() => Promise.resolve()),
  logWarnMock: vi.fn(() => Promise.resolve()),
}))

vi.mock("@/App", () => ({
  App: () => null,
}))

vi.mock("@tauri-apps/plugin-log", () => ({
  error: logErrorMock,
  warn: logWarnMock,
}))

vi.mock("react-dom/client", () => ({
  default: {
    createRoot: createRootMock,
  },
}))

const originalError = console.error
const originalWarn = console.warn

describe("main", () => {
  beforeEach(() => {
    vi.resetModules()
    createRootMock.mockClear()
    renderMock.mockClear()
    logErrorMock.mockClear()
    logWarnMock.mockClear()
    console.error = originalError
    console.warn = originalWarn
    delete (console as Console & { __openUsageLogForwarding?: unknown }).__openUsageLogForwarding
  })

  afterEach(() => {
    console.error = originalError
    console.warn = originalWarn
    delete (console as Console & { __openUsageLogForwarding?: unknown }).__openUsageLogForwarding
  })

  it("mounts app", async () => {
    document.body.innerHTML = '<div id="root"></div>'
    const { mountApp } = await import("@/main-entry")
    mountApp()
    expect(createRootMock).toHaveBeenCalled()
    expect(renderMock).toHaveBeenCalled()
  })

  it("installs console forwarding only once", async () => {
    const originalWarnMock = vi.fn()
    const originalErrorMock = vi.fn()
    console.warn = originalWarnMock
    console.error = originalErrorMock

    const { installConsoleLogForwarding } = await import("@/main-entry")
    installConsoleLogForwarding()
    installConsoleLogForwarding()

    console.warn("warning")
    console.error("error")

    expect(originalWarnMock).toHaveBeenCalledTimes(1)
    expect(originalErrorMock).toHaveBeenCalledTimes(1)
    expect(logWarnMock).toHaveBeenCalledTimes(1)
    expect(logErrorMock).toHaveBeenCalledTimes(1)
  })
})
