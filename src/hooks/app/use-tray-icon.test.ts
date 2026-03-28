import { renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { PluginMeta } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"

const {
  getByIdMock,
  resolveResourceMock,
  renderTrayBarsIconMock,
  getTrayPrimaryBarsMock,
} = vi.hoisted(() => ({
  getByIdMock: vi.fn(),
  resolveResourceMock: vi.fn(),
  renderTrayBarsIconMock: vi.fn(),
  getTrayPrimaryBarsMock: vi.fn(),
}))

vi.mock("@tauri-apps/api/path", () => ({
  resolveResource: resolveResourceMock,
}))

vi.mock("@tauri-apps/api/tray", () => ({
  TrayIcon: {
    getById: getByIdMock,
  },
}))

vi.mock("@/lib/tray-bars-icon", () => ({
  getTrayIconSizePx: vi.fn(() => 18),
  renderTrayBarsIcon: renderTrayBarsIconMock,
}))

vi.mock("@/lib/tray-primary-progress", () => ({
  getTrayPrimaryBars: getTrayPrimaryBarsMock,
}))

import { useTrayIcon } from "@/hooks/app/use-tray-icon"

describe("useTrayIcon", () => {
  const pluginsMeta: PluginMeta[] = [
    {
      id: "mock",
      name: "Mock",
      iconUrl: "data:image/svg+xml;base64,icon",
      lines: [],
      primaryCandidates: [],
    },
  ]

  const pluginSettings: PluginSettings = {
    order: ["mock"],
    disabled: [],
  }

  beforeEach(() => {
    vi.useRealTimers()
    getByIdMock.mockReset()
    resolveResourceMock.mockReset()
    renderTrayBarsIconMock.mockReset()
    getTrayPrimaryBarsMock.mockReset()

    resolveResourceMock.mockResolvedValue("/icons/tray-icon.png")
    renderTrayBarsIconMock.mockResolvedValue("rendered-icon")
    getTrayPrimaryBarsMock.mockReturnValue([{ id: "mock", fraction: 0.42 }])
  })

  it("falls back to percent text inside the provider icon when native tray titles are unavailable", async () => {
    const tray = {
      setIcon: vi.fn().mockResolvedValue(undefined),
      setIconAsTemplate: vi.fn().mockResolvedValue(undefined),
      setTooltip: vi.fn().mockResolvedValue(undefined),
    }
    getByIdMock.mockResolvedValue(tray)

    renderHook(() =>
      useTrayIcon({
        pluginsMeta,
        pluginSettings,
        pluginStates: {},
        displayMode: "left",
        menubarIconStyle: "provider",
        activeView: "home",
      })
    )

    await waitFor(() => {
      expect(getByIdMock).toHaveBeenCalledWith("tray")
    })

    await waitFor(() => {
      expect(renderTrayBarsIconMock).toHaveBeenCalled()
    })

    expect(renderTrayBarsIconMock).toHaveBeenCalledWith(
      expect.objectContaining({
        style: "provider",
        percentText: "42%",
      })
    )
    expect(tray.setTooltip).toHaveBeenCalledWith("UsageTray\nMock: 42%")
  })

  it("uses native tray title text when Windows tray title support is available", async () => {
    const tray = {
      setIcon: vi.fn().mockResolvedValue(undefined),
      setIconAsTemplate: vi.fn().mockResolvedValue(undefined),
      setTooltip: vi.fn().mockResolvedValue(undefined),
      setTitle: vi.fn().mockResolvedValue(undefined),
    }
    getByIdMock.mockResolvedValue(tray)

    renderHook(() =>
      useTrayIcon({
        pluginsMeta,
        pluginSettings,
        pluginStates: {},
        displayMode: "left",
        menubarIconStyle: "provider",
        activeView: "home",
      })
    )

    await waitFor(() => {
      expect(getByIdMock).toHaveBeenCalledWith("tray")
    })

    await waitFor(() => {
      expect(renderTrayBarsIconMock).toHaveBeenCalled()
    })

    expect(renderTrayBarsIconMock).toHaveBeenCalledWith(
      expect.objectContaining({
        style: "provider",
        percentText: undefined,
      })
    )
    expect(tray.setTitle).toHaveBeenCalledWith("42%")
    expect(tray.setTooltip).toHaveBeenCalledWith("UsageTray\nMock: 42%")
  })
})
