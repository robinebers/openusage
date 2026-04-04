import { render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const state = vi.hoisted(() => ({
  usePanelMock: vi.fn(),
  useAppVersionMock: vi.fn(),
  useAppUpdateMock: vi.fn(),
}))

vi.mock("@/components/app/app-content", () => ({
  AppContent: () => <div data-testid="app-content" />,
}))

vi.mock("@/components/panel-footer", () => ({
  PanelFooter: () => <div data-testid="panel-footer" />,
}))

vi.mock("@/components/side-nav", () => ({
  SideNav: () => <div data-testid="side-nav" />,
}))

vi.mock("@/hooks/app/use-panel", () => ({
  usePanel: state.usePanelMock,
}))

vi.mock("@/hooks/app/use-app-version", () => ({
  useAppVersion: state.useAppVersionMock,
}))

vi.mock("@/hooks/use-app-update", () => ({
  useAppUpdate: state.useAppUpdateMock,
}))

vi.mock("@/stores/app-ui-store", () => ({
  useAppUiStore: () => ({
    activeView: "home",
    setActiveView: vi.fn(),
    showAbout: false,
    setShowAbout: vi.fn(),
  }),
}))

import { AppShell } from "@/components/app/app-shell"

function createProps() {
  return {
    onRefreshAll: vi.fn(),
    navPlugins: [],
    displayPlugins: [],
    settingsPlugins: [],
    autoUpdateNextAt: null,
    selectedPlugin: null,
    onPluginContextAction: vi.fn(),
    isPluginRefreshAvailable: vi.fn(),
    onNavReorder: vi.fn(),
    appContentProps: {
      onRetryPlugin: vi.fn(),
      onReorder: vi.fn(),
      onToggle: vi.fn(),
      onAutoUpdateIntervalChange: vi.fn(),
      onThemeModeChange: vi.fn(),
      onDisplayModeChange: vi.fn(),
      onResetTimerDisplayModeChange: vi.fn(),
      onResetTimerDisplayModeToggle: vi.fn(),
      onMenubarIconStyleChange: vi.fn(),
      traySettingsPreview: {
        active: false,
        bars: [],
        iconUrl: null,
        primaryLabel: null,
      },
      onGlobalShortcutChange: vi.fn(),
      onStartOnLoginChange: vi.fn(),
    },
  }
}

describe("AppShell", () => {
  beforeEach(() => {
    state.usePanelMock.mockReturnValue({
      containerRef: { current: null },
      scrollRef: { current: null },
      canScrollDown: false,
      panelHeightPx: 560,
    })
    state.useAppVersionMock.mockReturnValue("0.0.0-test")
    state.useAppUpdateMock.mockReturnValue({
      updateStatus: { status: "idle" },
      triggerInstall: vi.fn(),
      checkForUpdates: vi.fn(),
    })
  })

  it("uses the styled panel scrollbar class on the scroll region", () => {
    const { container } = render(<AppShell {...createProps()} />)

    expect(screen.getByTestId("app-content")).toBeInTheDocument()
    expect(container.querySelector(".panel-scroll")).toBeTruthy()
  })
})
