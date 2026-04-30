import { renderHook, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { useAppPluginViews } from "@/hooks/app/use-app-plugin-views"
import type { PluginMeta } from "@/lib/plugin-types"
import type { PluginSettings } from "@/lib/settings"

function createPluginMeta(id: string, name: string): PluginMeta {
  return {
    id,
    name,
    iconUrl: `/${id}.svg`,
    brandColor: "#000000",
    lines: [],
    primaryCandidates: [],
  }
}

describe("useAppPluginViews", () => {
  it("derives display and nav plugins from settings order", () => {
    const pluginSettings: PluginSettings = {
      order: ["codex", "cursor"],
      disabled: ["cursor"],
    }

    const pluginsMeta = [
      createPluginMeta("cursor", "Cursor"),
      createPluginMeta("codex", "Codex"),
    ]

    const { result } = renderHook(() =>
      useAppPluginViews({
        activeView: "home",
        setActiveView: vi.fn(),
        selectedCodexProviderId: null,
        pluginSettings,
        pluginsMeta,
        pluginStates: {
          codex: {
            data: null,
            loading: true,
            error: null,
            lastManualRefreshAt: null,
            lastUpdatedAt: null,
          },
        },
      })
    )

    expect(result.current.displayPlugins).toHaveLength(1)
    expect(result.current.displayPlugins[0]?.meta.id).toBe("codex")
    expect(result.current.displayPlugins[0]?.loading).toBe(true)
    expect(result.current.navPlugins).toEqual([
      {
        id: "codex",
        name: "Codex",
        iconUrl: "/codex.svg",
        brandColor: "#000000",
      },
    ])
  })

  it("falls back to home when active provider becomes disabled", async () => {
    const setActiveView = vi.fn()
    const pluginSettings: PluginSettings = {
      order: ["codex"],
      disabled: ["codex"],
    }

    renderHook(() =>
      useAppPluginViews({
        activeView: "codex",
        setActiveView,
        selectedCodexProviderId: null,
        pluginSettings,
        pluginsMeta: [createPluginMeta("codex", "Codex")],
        pluginStates: {},
      })
    )

    await waitFor(() => {
      expect(setActiveView).toHaveBeenCalledWith("home")
    })
  })

  it("does not fall back while plugin settings are still loading", async () => {
    const setActiveView = vi.fn()
    const pluginsMeta = [createPluginMeta("codex", "Codex")]
    const { rerender } = renderHook(
      ({ pluginSettings }: { pluginSettings: PluginSettings | null }) =>
        useAppPluginViews({
          activeView: "codex",
          setActiveView,
          selectedCodexProviderId: null,
          pluginSettings,
          pluginsMeta,
          pluginStates: {},
        }),
      { initialProps: { pluginSettings: null } }
    )

    expect(setActiveView).not.toHaveBeenCalled()

    rerender({
      pluginSettings: {
        order: ["codex"],
        disabled: ["codex"],
      },
    })

    await waitFor(() => {
      expect(setActiveView).toHaveBeenCalledWith("home")
    })
  })

  it("returns selected plugin for active provider view", () => {
    const pluginSettings: PluginSettings = {
      order: ["codex"],
      disabled: [],
    }

    const { result } = renderHook(() =>
      useAppPluginViews({
        activeView: "codex",
        setActiveView: vi.fn(),
        selectedCodexProviderId: null,
        pluginSettings,
        pluginsMeta: [createPluginMeta("codex", "Codex")],
        pluginStates: {},
      })
    )

    expect(result.current.selectedPlugin?.meta.id).toBe("codex")
  })

  it("groups multiple Codex account providers into one nav and display item", () => {
    const pluginSettings: PluginSettings = {
      order: ["codex", "codex-slot-account-2", "cursor"],
      disabled: [],
    }

    const pluginsMeta = [
      createPluginMeta("codex", "Codex"),
      createPluginMeta("codex-slot-account-2", "Codex"),
      createPluginMeta("cursor", "Cursor"),
    ]

    const { result } = renderHook(() =>
      useAppPluginViews({
        activeView: "home",
        setActiveView: vi.fn(),
        selectedCodexProviderId: "codex-slot-account-2",
        pluginSettings,
        pluginsMeta,
        pluginStates: {
          "codex-slot-account-2": {
            data: { providerId: "codex-slot-account-2", displayName: "Codex", plan: "other@example.com - Pro 20x", lines: [], iconUrl: "" },
            loading: false,
            error: null,
            lastManualRefreshAt: null,
            lastUpdatedAt: 1,
          },
        },
      })
    )

    expect(result.current.navPlugins.map((plugin) => plugin.id)).toEqual(["codex", "cursor"])
    expect(result.current.displayPlugins.map((plugin) => plugin.meta.id)).toEqual(["codex", "cursor"])
    expect(result.current.displayPlugins[0]?.sourceProviderId).toBe("codex-slot-account-2")
    expect(result.current.displayPlugins[0]?.data?.plan).toBe("other@example.com - Pro 20x")
    expect(result.current.codexAccountOptions.map((option) => option.providerId)).toEqual(["codex", "codex-slot-account-2"])
  })
})
