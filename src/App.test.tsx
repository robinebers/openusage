import { render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi, beforeEach } from "vitest"

const state = vi.hoisted(() => ({
  invokeMock: vi.fn(),
  isTauriMock: vi.fn(() => false),
  setSizeMock: vi.fn(),
  currentMonitorMock: vi.fn(),
  startBatchMock: vi.fn(),
  savePluginSettingsMock: vi.fn(),
  loadPluginSettingsMock: vi.fn(),
  loadAutoUpdateIntervalMock: vi.fn(),
  saveAutoUpdateIntervalMock: vi.fn(),
  loadThemeModeMock: vi.fn(),
  saveThemeModeMock: vi.fn(),
  loadDisplayModeMock: vi.fn(),
  saveDisplayModeMock: vi.fn(),
  loadTrayIconStyleMock: vi.fn(),
  saveTrayIconStyleMock: vi.fn(),
  loadTrayShowPercentageMock: vi.fn(),
  saveTrayShowPercentageMock: vi.fn(),
  renderTrayBarsIconMock: vi.fn(),
  probeHandlers: null as null | { onResult: (output: any) => void; onBatchComplete: () => void },
  trayGetByIdMock: vi.fn(),
  traySetIconMock: vi.fn(),
  traySetIconAsTemplateMock: vi.fn(),
  resolveResourceMock: vi.fn(),
}))

const dndState = vi.hoisted(() => ({
  latestOnDragEnd: null as null | ((event: any) => void),
}))

const updaterState = vi.hoisted(() => ({
  checkMock: vi.fn(async () => null),
  relaunchMock: vi.fn(async () => undefined),
}))

const eventState = vi.hoisted(() => {
  const handlers = new Map<string, (event: any) => void>()
  return {
    handlers,
    listenMock: vi.fn(async (eventName: string, handler: (event: any) => void) => {
      handlers.set(eventName, handler)
      return () => { handlers.delete(eventName) }
    }),
  }
})

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
  isTauri: state.isTauriMock,
}))

vi.mock("@tauri-apps/api/event", () => ({
  listen: eventState.listenMock,
}))

vi.mock("@tauri-apps/api/tray", () => ({
  TrayIcon: {
    getById: state.trayGetByIdMock,
  },
}))

vi.mock("@tauri-apps/api/path", () => ({
  resolveResource: state.resolveResourceMock,
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

vi.mock("@tauri-apps/plugin-updater", () => ({
  check: updaterState.checkMock,
}))

vi.mock("@tauri-apps/plugin-process", () => ({
  relaunch: updaterState.relaunchMock,
}))

vi.mock("@/lib/tray-bars-icon", () => ({
  getTrayIconSizePx: () => 36,
  renderTrayBarsIcon: state.renderTrayBarsIconMock,
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
    loadDisplayMode: state.loadDisplayModeMock,
    saveDisplayMode: state.saveDisplayModeMock,
    loadTrayIconStyle: state.loadTrayIconStyleMock,
    saveTrayIconStyle: state.saveTrayIconStyleMock,
    loadTrayShowPercentage: state.loadTrayShowPercentageMock,
    saveTrayShowPercentage: state.saveTrayShowPercentageMock,
  }
})

import { App } from "@/App"

describe("App", () => {
  beforeEach(() => {
    state.probeHandlers = null
    state.invokeMock.mockReset()
    state.isTauriMock.mockReset()
    state.isTauriMock.mockReturnValue(false)
    state.setSizeMock.mockReset()
    state.currentMonitorMock.mockReset()
    state.startBatchMock.mockReset()
    state.savePluginSettingsMock.mockReset()
    state.loadPluginSettingsMock.mockReset()
    state.loadAutoUpdateIntervalMock.mockReset()
    state.saveAutoUpdateIntervalMock.mockReset()
    state.loadThemeModeMock.mockReset()
    state.saveThemeModeMock.mockReset()
    state.loadDisplayModeMock.mockReset()
    state.saveDisplayModeMock.mockReset()
    state.loadTrayIconStyleMock.mockReset()
    state.saveTrayIconStyleMock.mockReset()
    state.loadTrayShowPercentageMock.mockReset()
    state.saveTrayShowPercentageMock.mockReset()
    state.renderTrayBarsIconMock.mockReset()
    state.trayGetByIdMock.mockReset()
    state.traySetIconMock.mockReset()
    state.traySetIconAsTemplateMock.mockReset()
    state.resolveResourceMock.mockReset()
    eventState.handlers.clear()
    eventState.listenMock.mockReset()
    updaterState.checkMock.mockReset()
    updaterState.relaunchMock.mockReset()
    updaterState.checkMock.mockResolvedValue(null)
    state.savePluginSettingsMock.mockResolvedValue(undefined)
    state.saveAutoUpdateIntervalMock.mockResolvedValue(undefined)
    state.loadThemeModeMock.mockResolvedValue("system")
    state.saveThemeModeMock.mockResolvedValue(undefined)
    state.loadDisplayModeMock.mockResolvedValue("left")
    state.saveDisplayModeMock.mockResolvedValue(undefined)
    state.loadTrayIconStyleMock.mockResolvedValue("bars")
    state.saveTrayIconStyleMock.mockResolvedValue(undefined)
    state.loadTrayShowPercentageMock.mockResolvedValue(false)
    state.saveTrayShowPercentageMock.mockResolvedValue(undefined)
    state.renderTrayBarsIconMock.mockResolvedValue({})
    Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get() {
        return 100
      },
    })
    state.currentMonitorMock.mockResolvedValue({ size: { height: 1000 } })
    state.startBatchMock.mockResolvedValue(["a"])
    state.trayGetByIdMock.mockResolvedValue({
      setIcon: state.traySetIconMock.mockResolvedValue(undefined),
      setIconAsTemplate: state.traySetIconAsTemplateMock.mockResolvedValue(undefined),
    })
    state.resolveResourceMock.mockResolvedValue("/resource/icons/tray-icon.png")
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          { id: "a", name: "Alpha", iconUrl: "icon-a", primaryProgressLabel: null, lines: [{ type: "text", label: "Now", scope: "overview" }] },
          { id: "b", name: "Beta", iconUrl: "icon-b", primaryProgressLabel: null, lines: [] },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValue({ order: ["a"], disabled: [] })
    state.loadAutoUpdateIntervalMock.mockResolvedValue(15)
  })

  it("applies theme mode changes to document", async () => {
    const mq = {
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    } as unknown as MediaQueryList
    const mmSpy = vi.spyOn(window, "matchMedia").mockReturnValue(mq)

    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    // Dark
    await userEvent.click(await screen.findByRole("radio", { name: "Dark" }))
    expect(document.documentElement.classList.contains("dark")).toBe(true)

    // Light
    await userEvent.click(await screen.findByRole("radio", { name: "Light" }))
    expect(document.documentElement.classList.contains("dark")).toBe(false)

    // Back to system should subscribe to matchMedia changes
    await userEvent.click(await screen.findByRole("radio", { name: "System" }))
    expect(mq.addEventListener).toHaveBeenCalled()

    mmSpy.mockRestore()
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

  it("updates tray icon on probe results when plugin has a primary progress", async () => {
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          {
            id: "a",
            name: "Alpha",
            iconUrl: "icon-a",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a"], disabled: [] })

    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Init will trigger an icon generation attempt (bars exist but no data yet).
    await waitFor(() => expect(state.renderTrayBarsIconMock).toHaveBeenCalled())
    const callsBefore = state.renderTrayBarsIconMock.mock.calls.length

    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "progress", label: "Session", used: 50, limit: 100, format: { kind: "percent" } }],
    })

    await waitFor(() => expect(state.renderTrayBarsIconMock.mock.calls.length).toBeGreaterThan(callsBefore))
    await waitFor(() => expect(state.traySetIconMock).toHaveBeenCalled())
  })

  it("uses one metric for circle tray style", async () => {
    state.loadTrayIconStyleMock.mockResolvedValueOnce("circle")
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          {
            id: "a",
            name: "Alpha",
            iconUrl: "icon-a",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
          {
            id: "b",
            name: "Beta",
            iconUrl: "icon-b",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })

    render(<App />)
    await waitFor(() => expect(state.renderTrayBarsIconMock).toHaveBeenCalled())

    const firstCall = state.renderTrayBarsIconMock.mock.calls[0]?.[0]
    expect(firstCall.style).toBe("circle")
    expect(firstCall.bars).toHaveLength(1)
  })

  it("uses provider tray style and passes first provider icon", async () => {
    state.loadTrayIconStyleMock.mockResolvedValueOnce("provider")
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          {
            id: "a",
            name: "Alpha",
            iconUrl: "icon-a",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
          {
            id: "b",
            name: "Beta",
            iconUrl: "icon-b",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })

    render(<App />)
    await waitFor(() => expect(state.renderTrayBarsIconMock).toHaveBeenCalled())

    const firstCall = state.renderTrayBarsIconMock.mock.calls[0]?.[0]
    expect(firstCall.style).toBe("provider")
    expect(firstCall.bars).toHaveLength(1)
    expect(firstCall.providerIconUrl).toBe("icon-a")
    expect(firstCall.percentText).toBeUndefined()

    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "progress", label: "Session", used: 50, limit: 100, format: { kind: "percent" } }],
    })

    await waitFor(() => expect(state.renderTrayBarsIconMock.mock.calls.length).toBeGreaterThan(1))
    const latestCall = state.renderTrayBarsIconMock.mock.calls.at(-1)?.[0]
    expect(latestCall.style).toBe("provider")
    expect(latestCall.providerIconUrl).toBe("icon-a")
    expect(latestCall.percentText).toBe("50%")
  })

  it("uses text-only tray style", async () => {
    state.loadTrayIconStyleMock.mockResolvedValueOnce("textOnly")
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          {
            id: "a",
            name: "Alpha",
            iconUrl: "icon-a",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
          {
            id: "b",
            name: "Beta",
            iconUrl: "icon-b",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })

    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "progress", label: "Session", used: 50, limit: 100, format: { kind: "percent" } }],
    })

    await waitFor(() => expect(state.renderTrayBarsIconMock).toHaveBeenCalled())
    const latestCall = state.renderTrayBarsIconMock.mock.calls.at(-1)?.[0]
    expect(latestCall.style).toBe("textOnly")
    expect(latestCall.bars).toHaveLength(1)
    expect(latestCall.percentText).toBe("50%")
  })

  it("hides tray percent text when first fraction is missing and percentage enabled", async () => {
    state.loadTrayShowPercentageMock.mockResolvedValueOnce(true)
    state.invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          {
            id: "a",
            name: "Alpha",
            iconUrl: "icon-a",
            primaryCandidates: ["Session"],
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a"], disabled: [] })

    render(<App />)
    await waitFor(() => expect(state.renderTrayBarsIconMock).toHaveBeenCalled())

    const firstCall = state.renderTrayBarsIconMock.mock.calls[0]?.[0]
    expect(firstCall.style).toBe("bars")
    expect(firstCall.percentText).toBeUndefined()
  })

  it("covers about open/close callbacks", async () => {
    render(<App />)

    // Open about via version button in footer
    await userEvent.click(await screen.findByRole("button", { name: /OpenUsage/i }))
    await screen.findByText("Built by")

    // Close about via ESC key
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }))
    await waitFor(() => {
      expect(screen.queryByText("Built by")).not.toBeInTheDocument()
    })
  })

  it("updates display mode in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "Used" }))
    expect(state.saveDisplayModeMock).toHaveBeenCalledWith("used")
  })

  it("logs when saving display mode fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.saveDisplayModeMock.mockRejectedValueOnce(new Error("save display mode"))

    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "Used" }))
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())

    errorSpy.mockRestore()
  })

  it("updates tray icon style in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "Circle" }))
    expect(state.saveTrayIconStyleMock).toHaveBeenCalledWith("circle")
  })

  it("updates text-only tray icon style in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "%" }))
    expect(state.saveTrayIconStyleMock).toHaveBeenCalledWith("textOnly")
    expect(state.saveTrayShowPercentageMock).toHaveBeenCalledWith(true)
  })

  it("updates provider tray icon style in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "Provider" }))
    expect(state.saveTrayIconStyleMock).toHaveBeenCalledWith("provider")
    expect(state.saveTrayShowPercentageMock).toHaveBeenCalledWith(true)
  })

  it("updates tray show percentage in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByText("Show percentage"))
    expect(state.saveTrayShowPercentageMock).toHaveBeenCalledWith(true)
  })

  it("keeps tray show percentage checkbox visible and disabled for mandatory styles", async () => {
    const getTrayCheckbox = () => screen.getAllByRole("checkbox")[0]

    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "%" }))
    const textOnlyCheckbox = getTrayCheckbox()
    expect(textOnlyCheckbox).toBeVisible()
    expect(textOnlyCheckbox).toHaveAttribute("aria-disabled", "true")
    expect(textOnlyCheckbox).toBeChecked()

    await userEvent.click(await screen.findByRole("radio", { name: "Provider" }))
    const providerCheckbox = getTrayCheckbox()
    expect(providerCheckbox).toBeVisible()
    expect(providerCheckbox).toHaveAttribute("aria-disabled", "true")
    expect(providerCheckbox).toBeChecked()
  })

  it("auto-corrects tray show percentage when loading mandatory tray style", async () => {
    state.loadTrayIconStyleMock.mockResolvedValueOnce("provider")
    state.loadTrayShowPercentageMock.mockResolvedValueOnce(false)

    render(<App />)

    await waitFor(() => expect(state.saveTrayShowPercentageMock).toHaveBeenCalledWith(true))
  })

  it("logs when saving tray icon style fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.saveTrayIconStyleMock.mockRejectedValueOnce(new Error("save tray icon style"))

    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    await userEvent.click(await screen.findByRole("radio", { name: "Circle" }))
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())

    errorSpy.mockRestore()
  })

  it("shows provider not found when tray navigates to unknown view", async () => {
    state.isTauriMock.mockReturnValue(true)
    render(<App />)

    await waitFor(() => expect(eventState.listenMock).toHaveBeenCalled())
    const handler = eventState.handlers.get("tray:navigate")
    expect(handler).toBeTruthy()
    handler?.({ payload: "nope" })

    await screen.findByText("Provider not found")
  })

  it("hides the panel on Escape when running in Tauri", async () => {
    state.isTauriMock.mockReturnValue(true)
    render(<App />)

    await waitFor(() => expect(state.invokeMock).toHaveBeenCalledWith("list_plugins"))

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }))

    await waitFor(() => expect(state.invokeMock).toHaveBeenCalledWith("hide_panel"))
  })

  it("toggles plugins in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    const checkboxes = await screen.findAllByRole("checkbox")
    const pluginCheckbox = checkboxes[checkboxes.length - 1]
    await userEvent.click(pluginCheckbox)
    expect(state.savePluginSettingsMock).toHaveBeenCalled()
    await userEvent.click(pluginCheckbox)
    expect(state.savePluginSettingsMock).toHaveBeenCalledTimes(2)
  })

  it("updates auto-update interval in settings", async () => {
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    await userEvent.click(await screen.findByRole("radio", { name: "30 min" }))
    expect(state.saveAutoUpdateIntervalMock).toHaveBeenCalledWith(30)
  })

  it("logs when saving auto-update interval fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.saveAutoUpdateIntervalMock.mockRejectedValueOnce(new Error("save interval"))
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    await userEvent.click(await screen.findByRole("radio", { name: "30 min" }))
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("logs when loading display mode fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.loadDisplayModeMock.mockRejectedValueOnce(new Error("load display mode"))

    render(<App />)
    await waitFor(() => expect(state.invokeMock).toHaveBeenCalledWith("list_plugins"))
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())

    errorSpy.mockRestore()
  })

  it("logs when loading tray icon style fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.loadTrayIconStyleMock.mockRejectedValueOnce(new Error("load tray icon style"))

    render(<App />)
    await waitFor(() => expect(state.invokeMock).toHaveBeenCalledWith("list_plugins"))
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())

    errorSpy.mockRestore()
  })

  it("logs when saving theme mode fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.saveThemeModeMock.mockRejectedValueOnce(new Error("save theme"))
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])
    await userEvent.click(await screen.findByRole("radio", { name: "Light" }))
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
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
    const targetCheckbox = checkboxes[checkboxes.length - 1]
    await userEvent.click(targetCheckbox)
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
    const targetCheckbox = checkboxes[checkboxes.length - 1]
    await userEvent.click(targetCheckbox)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalledWith(["b"]))
  })

  it("uses fallback monitor sizing when monitor missing", async () => {
    state.currentMonitorMock.mockResolvedValueOnce(null)
    render(<App />)
    await waitFor(() => expect(state.setSizeMock).toHaveBeenCalled())
  })

  it("resizes again via ResizeObserver callback", async () => {
    const OriginalResizeObserver = globalThis.ResizeObserver
    const observeSpy = vi.fn()
    globalThis.ResizeObserver = class ResizeObserverImmediate {
      private cb: ResizeObserverCallback
      constructor(cb: ResizeObserverCallback) {
        this.cb = cb
      }
      observe() {
        observeSpy()
        this.cb([], this as unknown as ResizeObserver)
      }
      unobserve() {}
      disconnect() {}
    } as unknown as typeof ResizeObserver

    render(<App />)
    await waitFor(() => expect(observeSpy).toHaveBeenCalled())
    await waitFor(() => expect(state.setSizeMock).toHaveBeenCalled())

    globalThis.ResizeObserver = OriginalResizeObserver
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

  it("switches to provider detail view when selecting a plugin", async () => {
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Provide some data so detail view has content.
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "text", label: "Now", value: "Later" }],
    })

    // Click plugin in side nav (aria-label is plugin name)
    await userEvent.click(await screen.findByRole("button", { name: "Alpha" }))

    // Detail view uses ProviderDetailPage (scope=all) but should still render the provider card content.
    await screen.findByText("Now")
  })

  it("coalesces pending tray icon timers on multiple settings changes", async () => {
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })
    render(<App />)
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    // Toggle then reorder quickly (within debounce window) to force timer replacement.
    const checkboxes = await screen.findAllByRole("checkbox")
    const pluginCheckbox = checkboxes[checkboxes.length - 1]
    await userEvent.click(pluginCheckbox)
    dndState.latestOnDragEnd?.({ active: { id: "a" }, over: { id: "b" } })

    expect(state.savePluginSettingsMock).toHaveBeenCalled()
  })

  it("logs when tray handle cannot be loaded", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.trayGetByIdMock.mockRejectedValueOnce(new Error("no tray"))
    render(<App />)
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("logs when tray gauge resource cannot be resolved", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.resolveResourceMock.mockRejectedValueOnce(new Error("no resource"))
    render(<App />)
    await waitFor(() => expect(errorSpy).toHaveBeenCalled())
    errorSpy.mockRestore()
  })

  it("logs error when retry plugin batch fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Push an error result to show Retry button
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "badge", label: "Error", text: "Something failed" }],
    })

    // Make startBatch reject on next call (the retry)
    state.startBatchMock.mockRejectedValueOnce(new Error("retry failed"))

    const retry = await screen.findByRole("button", { name: "Retry" })
    await userEvent.click(retry)

    await waitFor(() =>
      expect(errorSpy).toHaveBeenCalledWith("Failed to retry plugin:", expect.any(Error))
    )
    errorSpy.mockRestore()
  })

  it("sets next update to null when changing interval with all plugins disabled", async () => {
    // All plugins disabled
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: ["a", "b"] })
    render(<App />)

    // Go to settings
    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    // Change interval - this triggers the else branch (enabledIds.length === 0)
    await userEvent.click(await screen.findByRole("radio", { name: "30 min" }))

    expect(state.saveAutoUpdateIntervalMock).toHaveBeenCalledWith(30)
  })

  it("covers interval change branch when plugins exist", async () => {
    // This test ensures the interval change logic is exercised with enabled plugins
    // to cover the if branch (enabledIds.length > 0 sets nextAt)
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a", "b"], disabled: [] })
    render(<App />)

    const settingsButtons = await screen.findAllByRole("button", { name: "Settings" })
    await userEvent.click(settingsButtons[0])

    // Change interval - this triggers the if branch (enabledIds.length > 0)
    await userEvent.click(await screen.findByRole("radio", { name: "1 hour" }))

    expect(state.saveAutoUpdateIntervalMock).toHaveBeenCalledWith(60)
  })

  it("fires auto-update interval and schedules next", async () => {
    vi.useFakeTimers()
    // Set a very short interval for testing (5 min = 300000ms)
    state.loadAutoUpdateIntervalMock.mockResolvedValueOnce(5)
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a"], disabled: [] })

    render(<App />)

    // Wait for initial setup
    await vi.waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Clear the initial batch call count
    const initialCalls = state.startBatchMock.mock.calls.length

    // Advance time by 5 minutes to trigger the interval
    await vi.advanceTimersByTimeAsync(5 * 60 * 1000)

    // The interval should have fired, calling startBatch again
    await vi.waitFor(() =>
      expect(state.startBatchMock.mock.calls.length).toBeGreaterThan(initialCalls)
    )

    vi.useRealTimers()
  })

  it("logs error when auto-update batch fails", async () => {
    vi.useFakeTimers()
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    state.loadAutoUpdateIntervalMock.mockResolvedValueOnce(5)
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a"], disabled: [] })
    // First call succeeds (initial batch), subsequent calls fail
    state.startBatchMock
      .mockResolvedValueOnce(["a"])
      .mockRejectedValue(new Error("auto-update failed"))

    render(<App />)

    // Wait for initial batch
    await vi.waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Advance time to trigger the interval (which will fail)
    await vi.advanceTimersByTimeAsync(5 * 60 * 1000)

    await vi.waitFor(() =>
      expect(errorSpy).toHaveBeenCalledWith("Failed to start auto-update batch:", expect.any(Error))
    )

    errorSpy.mockRestore()
    vi.useRealTimers()
  })

  it("logs error when loading auto-update interval fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.loadAutoUpdateIntervalMock.mockRejectedValueOnce(new Error("load interval failed"))
    render(<App />)
    await waitFor(() =>
      expect(errorSpy).toHaveBeenCalledWith("Failed to load auto-update interval:", expect.any(Error))
    )
    errorSpy.mockRestore()
  })

  it("logs error when loading theme mode fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    state.loadThemeModeMock.mockRejectedValueOnce(new Error("load theme failed"))
    render(<App />)
    await waitFor(() =>
      expect(errorSpy).toHaveBeenCalledWith("Failed to load theme mode:", expect.any(Error))
    )
    errorSpy.mockRestore()
  })

  it("tracks manual refresh and clears cooldown flag on result", async () => {
    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Show error to get Retry button
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "badge", label: "Error", text: "Network error" }],
    })

    const retryButton = await screen.findByRole("button", { name: "Retry" })
    await userEvent.click(retryButton)

    // Simulate successful probe result after retry (isManual branch)
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "text", label: "Now", value: "OK" }],
    })

    // The result should be displayed (Now is the label from the provider-card)
    await screen.findByText("Now")
  })

  it("handles retry when plugin settings change to all disabled", async () => {
    // This test covers the resetAutoUpdateSchedule branch when enabledIds.length === 0
    // Setup: start with one plugin, show error, then disable it during retry flow

    // Use a mutable settings object we can modify
    let currentSettings = { order: ["a", "b"], disabled: ["b"] }
    state.loadPluginSettingsMock.mockImplementation(async () => currentSettings)
    state.savePluginSettingsMock.mockImplementation(async (newSettings) => {
      currentSettings = newSettings
    })

    render(<App />)
    await waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Show error state for plugin "a"
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "badge", label: "Error", text: "Network error" }],
    })

    // Find and prepare to click retry
    const retryButton = await screen.findByRole("button", { name: "Retry" })

    // Before clicking, disable "a" to make enabledIds.length === 0 when resetAutoUpdateSchedule runs
    // This simulates a race condition where settings change mid-action
    currentSettings = { order: ["a", "b"], disabled: ["a", "b"] }

    await userEvent.click(retryButton)

    // The retry should still work (startBatch called) but resetAutoUpdateSchedule
    // should hit the enabledIds.length === 0 branch
    expect(state.startBatchMock).toHaveBeenCalledWith(["a"])
  })

  it("updates tray icon without requestAnimationFrame (regression test for hidden panel)", async () => {
    vi.useFakeTimers()

    // Stub requestAnimationFrame to never call the callback - simulates hidden panel throttling
    const originalRaf = window.requestAnimationFrame
    const rafSpy = vi.fn()
    window.requestAnimationFrame = rafSpy

    // Setup plugin with primary progress
    state.invokeMock.mockImplementationOnce(async (cmd: string) => {
      if (cmd === "list_plugins") {
        return [
          {
            id: "a",
            name: "Alpha",
            iconUrl: "icon-a",
            primaryProgressLabel: "Session",
            lines: [{ type: "progress", label: "Session", scope: "overview" }],
          },
        ]
      }
      return null
    })
    state.loadPluginSettingsMock.mockResolvedValueOnce({ order: ["a"], disabled: [] })

    render(<App />)
    await vi.waitFor(() => expect(state.startBatchMock).toHaveBeenCalled())

    // Wait for tray to be ready
    await vi.waitFor(() => expect(state.trayGetByIdMock).toHaveBeenCalled())

    // Clear any initial calls
    state.traySetIconMock.mockClear()

    // Trigger a probe result
    state.probeHandlers?.onResult({
      providerId: "a",
      displayName: "Alpha",
      iconUrl: "icon-a",
      lines: [{ type: "progress", label: "Session", used: 50, limit: 100, format: { kind: "percent" } }],
    })

    // Advance timers to trigger the debounced tray update (500ms probe debounce)
    await vi.advanceTimersByTimeAsync(600)

    // Tray icon should have been updated even though requestAnimationFrame was never called
    expect(rafSpy).not.toHaveBeenCalled()
    expect(state.traySetIconMock).toHaveBeenCalled()

    window.requestAnimationFrame = originalRaf
    vi.useRealTimers()
  })
})
