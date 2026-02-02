import { render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi, beforeEach } from "vitest"

const state = vi.hoisted(() => ({
  invokeMock: vi.fn(),
  setSizeMock: vi.fn(),
  currentMonitorMock: vi.fn(),
  startBatchMock: vi.fn(),
  savePluginSettingsMock: vi.fn(),
  loadPluginSettingsMock: vi.fn(),
  loadAutoUpdateIntervalMock: vi.fn(),
  saveAutoUpdateIntervalMock: vi.fn(),
  loadThemeModeMock: vi.fn(),
  saveThemeModeMock: vi.fn(),
  probeHandlers: null as null | { onResult: (output: any) => void; onBatchComplete: () => void },
}))

const dndState = vi.hoisted(() => ({
  latestOnDragEnd: null as null | ((event: any) => void),
}))

vi.mock("@dnd-kit/core", () => ({
  DndContext: ({ children, onDragEnd }: { children: ReactNode; onDragEnd?: (event: any) => void }) => {
    dndState.latestOnDragEnd = onDragEnd ?? null
    return <div>{children}</div>
  },
  closestCenter: vi.fn(),
  PointerSensor: class {},
  KeyboardSensor: class {},
  useSensor: vi.fn((_sensor: any, options?: any) => ({ sensor: _sensor, options })),
  useSensors: vi.fn((...sensors: any[]) => sensors),
}))

vi.mock("@dnd-kit/sortable", () => ({
  arrayMove: (items: any[], from: number, to: number) => {
    const next = [...items]
    const [moved] = next.splice(from, 1)
    next.splice(to, 0, moved)
    return next
  },
  SortableContext: ({ children }: { children: ReactNode }) => <div>{children}</div>,
  sortableKeyboardCoordinates: vi.fn(),
  useSortable: () => ({
    attributes: {},
    listeners: {},
    setNodeRef: vi.fn(),
    transform: null,
    transition: undefined,
    isDragging: false,
  }),
  verticalListSortingStrategy: vi.fn(),
}))

vi.mock("@dnd-kit/utilities", () => ({
  CSS: { Transform: { toString: () => "" } },
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: state.invokeMock,
  isTauri: () => false,
}))

vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ setSize: state.setSizeMock }),
  PhysicalSize: class {
    width: number
    height: number
    constructor(width: number, height: number) {
      this.width = width
      this.height = height
    }
  },
  currentMonitor: state.currentMonitorMock,
}))

vi.mock("@tauri-apps/api/app", () => ({
  getVersion: () => Promise.resolve("0.0.0-test"),
}))

vi.mock("@/hooks/use-probe-events", () => ({
  useProbeEvents: (handlers: { onResult: (output: any) => void; onBatchComplete: () => void }) => {
    state.probeHandlers = handlers
    return { startBatch: state.startBatchMock }
  },
}))

vi.mock("@/lib/settings", async () => {
  const actual = await vi.importActual<typeof import("@/lib/settings")>("@/lib/settings")
  return {
    ...actual,
    loadPluginSettings: state.loadPluginSettingsMock,
    savePluginSettings: state.savePluginSettingsMock,
    loadAutoUpdateInterval: state.loadAutoUpdateIntervalMock,
    saveAutoUpdateInterval: state.saveAutoUpdateIntervalMock,
    loadThemeMode: state.loadThemeModeMock,
    saveThemeMode: state.saveThemeModeMock,
  }
})

import App from "@/App"

describe("App", () => {
  beforeEach(() => {
    state.probeHandlers = null
    state.invokeMock.mockReset()
    state.setSizeMock.mockReset()
    state.currentMonitorMock.mockReset()
    state.startBatchMock.mockReset()
    state.savePluginSettingsMock.mockReset()
    state.loadPluginSettingsMock.mockReset()
    state.loadAutoUpdateIntervalMock.mockReset()
    state.saveAutoUpdateIntervalMock.mockReset()
    state.loadThemeModeMock.mockReset()
    state.saveThemeModeMock.mockReset()
    state.savePluginSettingsMock.mockResolvedValue(undefined)
    state.saveAutoUpdateIntervalMock.mockResolvedValue(undefined)
    state.loadThemeModeMock.mockResolvedValue("system")
    state.saveThemeModeMock.mockResolvedValue(undefined)
    Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        return 100
      },
    })
    state.currentMonitorMock.mockResolvedValue({ size: { height: 1000 } })
    state.startBatchMock.mockResolvedValue(["a"])
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          { id: "a", name: "Alpha", iconUrl: "icon-a", lines: [{ type: "text", label: "Label" }] },
          { id: "b", name: "Beta", iconUrl: "icon-b", lines: [] },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValue({ order: ["a"], disabled: [] })
    state.loadAutoUpdateIntervalMock.mockResolvedValue(15)
  })

  it("loads plugins, normalizes settings, and renders overview", async () => {
    render(<App />)
    await waitFor(() => expect(state.invokeMock).toHaveBeenCalledWith("list_plugins"))
    await waitFor(() => expect(state.savePluginSettingsMock).toHaveBeenCalled())
    expect(screen.getByText("Alpha")).toBeInTheDocument()
    expect(state.setSizeMock).toHaveBeenCalled()
  })

  it("skips saving settings when already normalized", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })
    render(<App />)
    await waitFor(() => expect(state.invokeMock).toHaveBeenCalledWith("list_plugins"))
    expect(screen.getAllByText("Alpha").length).toBeGreaterThan(0)
    expect(state.savePluginSettingsMock).not.toHaveBeenCalled()
  })

  it("handles probe results", async () => {
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    expect(state.probeHandlers).not.toBeNull()
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "text", label: "Now", value: "Later" }],
    })
    state.probeHandlers?.onBatchComplete()
    await screen.findByText("Now")
  })

  it("toggles plugins in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    const checkboxes = await screen.findAllByRole("checkbox")
    await userEvent.click(checkboxes[0])
    expect(state.savePluginSettingsMock).toHaveBeenCalled()
    await userEvent.click(checkboxes[0])
    expect(state.savePluginSettingsMock).toHaveBeenCalledTimes(2)
  })

  it("updates auto-update interval in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    await userEvent.click(await screen.findByRole("radio", { name: "30 min" }))
    expect(state.saveAutoUpdateIntervalMock).toHaveBeenCalledWith(30)
  })

  it("retries a plugin on error", async () => {
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "badge", label: "Error", text: "Bad" }],
    })
    const retry = await screen.findByRole("button", { name: "Retry" })
    await userEvent.click(retry)
    expect(state.startBatchMock).toHaveBeenCalledWith(["a"])
  })

  it("shows empty state when all plugins disabled", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["a", "b"] })
    render(<App />)
    await screen.findByText("No providers enabled")
    expect(screen.getByText("Paused")).toBeInTheDocument()
  })

  it("handles plugin list load failure", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        throw new Error("boom")
      }
      return null
    })
    render(<App />)
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("handles initial batch failure", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.startBatchMock.mockRejectedValueOnce(new Error("fail"))
    render(<App />)
    const errors = await screen.findAllByText("Failed to start probe")
    expect(errors.length).toBeGreaterThan(0)
    errorSpy.mockRestore()
  })


  it("handles enable toggle failures", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["b"] })
    state.startBatchMock
      .mockResolvedValueOnce(["a"])
      .mockRejectedValueOnce(new Error("enable fail"))
    state.savePluginSettingsMock.mockRejectedValueOnce(new Error("save fail"))
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    const checkboxes = await screen.findAllByRole("checkbox")
    await userEvent.click(checkboxes[1])
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it("enables disabled plugin and starts batch", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["b"] })
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    const checkboxes = await screen.findAllByRole("checkbox")
    await userEvent.click(checkboxes[1])
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalledWith(["b"]))
  })

  it("uses fallback monitor sizing when monitor missing", async () => {
    state.currentMonitorMock.mockResolvedValueOnce(null)
    render(<App />)
    await waitFor(() => expect(state.setSizeMock).toHaveBeenCalled())
  })

  it("logs resize failures", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.setSizeMock.mockRejectedValueOnce(new Error("size fail"))
    render(<App />)
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("logs when saving plugin order fails", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })
    state.savePluginSettingsMock.mockRejectedValueOnce(new Error("save order"))
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    dndState.latestOnDragEnd?.({ active: { id: "a" }, over: { id: "b" } })
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("handles reordering plugins", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    dndState.latestOnDragEnd?.({ active: { id: "a" }, over: { id: "b" } })
    expect(state.savePluginSettingsMock).toHaveBeenCalled()
  })
})
