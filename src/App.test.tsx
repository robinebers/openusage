import { fireEvent, render, screen, waitFor } from "@testing-library/react"
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
    state.savePluginSettingsMock.mockResolvedValue(undefined)
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

  it("handles probe results + refresh", async () => {
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
    const refreshButtons = screen.getAllByRole("button", { name: "Refresh all" })
    await userEvent.click(refreshButtons[0])
    expect(state.startBatchMock).toHaveBeenLastCalledWith(["a", "b"])
  })

  it("shows errors when refresh batch fails", async () => {
    state.startBatchMock.mockResolvedValueOnce(["a"])
    state.startBatchMock.mockRejectedValueOnce(new Error("fail refresh"))
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    const refreshButtons = screen.getAllByRole("button", { name: "Refresh all" })
    await userEvent.click(refreshButtons[0])
    const errors = await screen.findAllByText("Failed to start probe")
    expect(errors.length).toBeGreaterThan(0)
    errorSpy.mockRestore()
  })

  it("toggles plugins in settings", async () => {
    render(<App />)
    const settingsTabs = await screen.findAllByRole("tab", { name: "Settings" })
    await userEvent.click(settingsTabs[0])
    const checkboxes = await screen.findAllByRole("checkbox")
    await userEvent.click(checkboxes[0])
    expect(state.savePluginSettingsMock).toHaveBeenCalled()
    await userEvent.click(checkboxes[0])
    expect(state.savePluginSettingsMock).toHaveBeenCalledTimes(2)
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
    const retry = await screen.findByText("Retry")
    await userEvent.click(retry)
    expect(state.startBatchMock).toHaveBeenCalledWith(["a"])
  })

  it("shows empty state when all plugins disabled", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["a", "b"] })
    render(<App />)
    await screen.findByText("No providers enabled")
    const refreshButtons = screen.getAllByRole("button", { name: "Refresh all" })
    const disabledButton = refreshButtons.find((button) => button.getAttribute("tabindex") === "-1")
    expect(disabledButton).toBeTruthy()
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

  it("skips refresh when on cooldown", async () => {
    const now = new Date("2026-02-02T00:00:00.000Z").getTime()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    const refreshButtons = screen.getAllByRole("button", { name: "Refresh all" })
    fireEvent.click(refreshButtons[0])
    expect(state.startBatchMock).toHaveBeenCalledTimes(2)
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "text", label: "Now", value: "Later" }],
    })
    fireEvent.click(refreshButtons[0])
    expect(state.startBatchMock).toHaveBeenCalledTimes(3)
    expect(state.startBatchMock).toHaveBeenLastCalledWith(["b"])
    nowSpy.mockRestore()
  })

  it("skips refresh when all plugins are on cooldown", async () => {
    const now = new Date("2026-02-02T00:00:00.000Z").getTime()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    const refreshButtons = screen.getAllByRole("button", { name: "Refresh all" })
    await userEvent.click(refreshButtons[0])
    const callCount = state.startBatchMock.mock.calls.length
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "text", label: "Now", value: "Later" }],
    })
    state.probeHandlers?.onResult({
      providerId: "b",
      displayName: "Beta",
      iconUrl: "icon-b",
      lines: [{ type: "text", label: "Now", value: "Later" }],
    })
    await userEvent.click(refreshButtons[0])
    expect(state.startBatchMock).toHaveBeenCalledTimes(callCount)
    nowSpy.mockRestore()
  })

  it("handles enable toggle failures", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["b"] })
    state.startBatchMock
      .mockResolvedValueOnce(["a"])
      .mockRejectedValueOnce(new Error("enable fail"))
    state.savePluginSettingsMock.mockRejectedValueOnce(new Error("save fail"))
    render(<App />)
    const settingsTabs = await screen.findAllByRole("tab", { name: "Settings" })
    await userEvent.click(settingsTabs[0])
    const checkboxes = await screen.findAllByRole("checkbox")
    await userEvent.click(checkboxes[1])
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it("enables disabled plugin and starts batch", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["b"] })
    render(<App />)
    const settingsTabs = await screen.findAllByRole("tab", { name: "Settings" })
    await userEvent.click(settingsTabs[0])
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
    const settingsTabs = await screen.findAllByRole("tab", { name: "Settings" })
    await userEvent.click(settingsTabs[0])
    dndState.latestOnDragEnd?.({ active: { id: "a" }, over: { id: "b" } })
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("cleans up cooldown timer when active", async () => {
    const now = new Date("2026-02-02T00:00:00.000Z").getTime()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(now)
    const setIntervalSpy = vi.spyOn(global, "setInterval")
    const clearIntervalSpy = vi.spyOn(global, "clearInterval")
    const { unmount } = render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())
    const refreshButtons = screen.getAllByRole("button", { name: "Refresh all" })
    await userEvent.click(refreshButtons[0])
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "text", label: "Now", value: "Later" }],
    })
    await waitFor(() => expect(setIntervalSpy).toHaveBeenCalled())
    unmount()
    expect(clearIntervalSpy).toHaveBeenCalled()
    clearIntervalSpy.mockRestore()
    setIntervalSpy.mockRestore()
    nowSpy.mockRestore()
  })

  it("handles reordering plugins", async () => {
    render(<App />)
    const settingsTabs = await screen.findAllByRole("tab", { name: "Settings" })
    await userEvent.click(settingsTabs[0])
    dndState.latestOnDragEnd?.({ active: { id: "a" }, over: { id: "b" } })
    expect(state.savePluginSettingsMock).toHaveBeenCalled()
  })
})
