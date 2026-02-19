import { cleanup, render, screen } from "@testing-library/react"
import type { ReactNode } from "react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"

let latestOnDragEnd: ((event: any) => void) | undefined

vi.mock("@dnd-kit/core", () => ({
  DndContext: ({ children, onDragEnd }: { children: ReactNode; onDragEnd?: (event: any) => void }) => {
    latestOnDragEnd = onDragEnd
    return <div data-testid="dnd-context">{children}</div>
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

import { SettingsPage } from "@/pages/settings"

const defaultProps = {
  plugins: [{ id: "a", name: "Alpha", enabled: true }],
  onReorder: vi.fn(),
  onToggle: vi.fn(),
  autoUpdateInterval: 15 as const,
  onAutoUpdateIntervalChange: vi.fn(),
  themeMode: "system" as const,
  onThemeModeChange: vi.fn(),
  displayMode: "used" as const,
  onDisplayModeChange: vi.fn(),
  resetTimerDisplayMode: "relative" as const,
  onResetTimerDisplayModeChange: vi.fn(),
  trayIconStyle: "bars" as const,
  onTrayIconStyleChange: vi.fn(),
  trayShowPercentage: false,
  onTrayShowPercentageChange: vi.fn(),
  globalShortcut: null,
  onGlobalShortcutChange: vi.fn(),
  startOnLogin: false,
  onStartOnLoginChange: vi.fn(),
  cliStatus: null,
  cliBusy: false,
  showCliPrompt: false,
  onCliInstall: vi.fn(),
  onCliUninstall: vi.fn(),
  onCliDismissPrompt: vi.fn(),
}

afterEach(() => {
  cleanup()
})

function getTrayShowPercentageCheckbox() {
  return screen.getAllByRole("checkbox")[0]
}

describe("SettingsPage", () => {
  it("toggles plugins", async () => {
    const onToggle = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        trayIconStyle="textOnly"
        plugins={[
          { id: "b", name: "Beta", enabled: false },
        ]}
        onToggle={onToggle}
      />
    )
    const checkboxes = screen.getAllByRole("checkbox")
    await userEvent.click(checkboxes[checkboxes.length - 1])
    expect(onToggle).toHaveBeenCalledWith("b")
  })

  it("reorders plugins on drag end", () => {
    const onReorder = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        plugins={[
          { id: "a", name: "Alpha", enabled: true },
          { id: "b", name: "Beta", enabled: true },
        ]}
        onReorder={onReorder}
      />
    )
    latestOnDragEnd?.({ active: { id: "a" }, over: { id: "b" } })
    expect(onReorder).toHaveBeenCalledWith(["b", "a"])
  })

  it("ignores invalid drag end", () => {
    const onReorder = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onReorder={onReorder}
      />
    )
    latestOnDragEnd?.({ active: { id: "a" }, over: null })
    latestOnDragEnd?.({ active: { id: "a" }, over: { id: "a" } })
    expect(onReorder).not.toHaveBeenCalled()
  })

  it("updates auto-update interval", async () => {
    const onAutoUpdateIntervalChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onAutoUpdateIntervalChange={onAutoUpdateIntervalChange}
      />
    )
    await userEvent.click(screen.getByText("30 min"))
    expect(onAutoUpdateIntervalChange).toHaveBeenCalledWith(30)
  })

  it("shows auto-update helper text", () => {
    render(<SettingsPage {...defaultProps} />)
    expect(screen.getByText("How obsessive are you")).toBeInTheDocument()
  })

  it("renders app theme section with theme options", () => {
    render(<SettingsPage {...defaultProps} />)
    expect(screen.getByText("App Theme")).toBeInTheDocument()
    expect(screen.getByText("How it looks around here")).toBeInTheDocument()
    expect(screen.getByText("System")).toBeInTheDocument()
    expect(screen.getByText("Light")).toBeInTheDocument()
    expect(screen.getByText("Dark")).toBeInTheDocument()
  })

  it("updates theme mode", async () => {
    const onThemeModeChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onThemeModeChange={onThemeModeChange}
      />
    )
    await userEvent.click(screen.getByText("Dark"))
    expect(onThemeModeChange).toHaveBeenCalledWith("dark")
  })

  it("updates display mode", async () => {
    const onDisplayModeChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onDisplayModeChange={onDisplayModeChange}
      />
    )
    await userEvent.click(screen.getByRole("radio", { name: "Left" }))
    expect(onDisplayModeChange).toHaveBeenCalledWith("left")
  })

  it("updates reset timer display mode", async () => {
    const onResetTimerDisplayModeChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onResetTimerDisplayModeChange={onResetTimerDisplayModeChange}
      />
    )
    await userEvent.click(screen.getByRole("radio", { name: /Absolute/ }))
    expect(onResetTimerDisplayModeChange).toHaveBeenCalledWith("absolute")
  })

  it("renders tray icon style section", () => {
    render(<SettingsPage {...defaultProps} />)
    expect(screen.getByText("Bar Icon")).toBeInTheDocument()
    expect(screen.getByText("The little guy up top")).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "Bars" })).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "Circle" })).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "Provider" })).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "%" })).toBeInTheDocument()
  })

  it("renders renamed usage section heading", () => {
    render(<SettingsPage {...defaultProps} />)
    expect(screen.getByText("Usage Mode")).toBeInTheDocument()
  })

  it("renders reset timers section heading", () => {
    render(<SettingsPage {...defaultProps} />)
    expect(screen.getByText("Reset Timers")).toBeInTheDocument()
  })

  it("shows cli first-launch prompt and handles actions", async () => {
    const onCliInstall = vi.fn()
    const onCliDismissPrompt = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        showCliPrompt
        onCliInstall={onCliInstall}
        onCliDismissPrompt={onCliDismissPrompt}
      />
    )

    expect(screen.getByText("Use OpenUsage in Terminal")).toBeInTheDocument()
    await userEvent.click(screen.getAllByRole("button", { name: "Install CLI" })[0])
    expect(onCliInstall).toHaveBeenCalledTimes(1)
    await userEvent.click(screen.getByRole("button", { name: "Not now" }))
    expect(onCliDismissPrompt).toHaveBeenCalledTimes(1)
  })

  it("renders cli section status and action buttons", async () => {
    const onCliInstall = vi.fn()
    const onCliUninstall = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        cliStatus={{
          installed: true,
          installPath: "/Users/test/.local/bin/openusage-cli",
          pluginsDir: "/Users/test/Library/Application Support/com.sunstory.openusage/plugins",
          pathExport: "export PATH=\"$HOME/.local/bin:$PATH\"",
          pluginsExport:
            "export OPENUSAGE_PLUGINS_DIR=\"/Users/test/Library/Application Support/com.sunstory.openusage/plugins\"",
        }}
        onCliInstall={onCliInstall}
        onCliUninstall={onCliUninstall}
      />
    )

    expect(screen.getByText("CLI")).toBeInTheDocument()
    expect(screen.getByText("Installed")).toBeInTheDocument()
    expect(screen.getByText(/Command path:/)).not.toBeVisible()
    await userEvent.click(screen.getByText("Paths"))
    expect(screen.getByText(/Command path:/)).toBeVisible()
    expect(screen.getByText(/Plugins path:/)).toBeVisible()
    await userEvent.click(screen.getByRole("button", { name: "Reinstall CLI" }))
    expect(onCliInstall).toHaveBeenCalledTimes(1)
    await userEvent.click(screen.getByRole("button", { name: "Uninstall CLI" }))
    expect(onCliUninstall).toHaveBeenCalledTimes(1)
  })

  it("updates tray icon style", async () => {
    const onTrayIconStyleChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onTrayIconStyleChange={onTrayIconStyleChange}
      />
    )
    await userEvent.click(screen.getByRole("radio", { name: "Circle" }))
    expect(onTrayIconStyleChange).toHaveBeenCalledWith("circle")
  })

  it("updates text-only tray icon style", async () => {
    const onTrayIconStyleChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onTrayIconStyleChange={onTrayIconStyleChange}
      />
    )
    await userEvent.click(screen.getByRole("radio", { name: "%" }))
    expect(onTrayIconStyleChange).toHaveBeenCalledWith("textOnly")
  })

  it("updates provider tray icon style", async () => {
    const onTrayIconStyleChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onTrayIconStyleChange={onTrayIconStyleChange}
      />
    )
    await userEvent.click(screen.getByRole("radio", { name: "Provider" }))
    expect(onTrayIconStyleChange).toHaveBeenCalledWith("provider")
  })

  it("always shows percentage checkbox and enforces mandatory styles", () => {
    const { rerender } = render(
      <SettingsPage
        {...defaultProps}
        trayIconStyle="bars"
      />
    )
    expect(screen.getByText("Show percentage")).toBeInTheDocument()
    expect(getTrayShowPercentageCheckbox().getAttribute("aria-disabled")).not.toBe("true")

    rerender(
      <SettingsPage
        {...defaultProps}
        trayIconStyle="circle"
      />
    )
    expect(getTrayShowPercentageCheckbox().getAttribute("aria-disabled")).not.toBe("true")

    rerender(
      <SettingsPage
        {...defaultProps}
        trayIconStyle="provider"
      />
    )
    expect(getTrayShowPercentageCheckbox()).toHaveAttribute("aria-disabled", "true")
    expect(getTrayShowPercentageCheckbox()).toBeChecked()

    rerender(
      <SettingsPage
        {...defaultProps}
        trayIconStyle="textOnly"
      />
    )
    expect(getTrayShowPercentageCheckbox()).toHaveAttribute("aria-disabled", "true")
    expect(getTrayShowPercentageCheckbox()).toBeChecked()
  })

  it("toggles show percentage checkbox", async () => {
    const onTrayShowPercentageChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        trayShowPercentage
        onTrayShowPercentageChange={onTrayShowPercentageChange}
      />
    )
    await userEvent.click(screen.getByText("Show percentage"))
    expect(onTrayShowPercentageChange).toHaveBeenCalled()
    expect(onTrayShowPercentageChange.mock.calls[0]?.[0]).toBe(false)
  })

  it("toggles start on login checkbox", async () => {
    const onStartOnLoginChange = vi.fn()
    render(
      <SettingsPage
        {...defaultProps}
        onStartOnLoginChange={onStartOnLoginChange}
      />
    )
    await userEvent.click(screen.getByText("Start on login"))
    expect(onStartOnLoginChange).toHaveBeenCalledWith(true)
  })
})
