import { renderHook } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { useSettingsPluginList } from "@/hooks/app/use-settings-plugin-list"
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

describe("useSettingsPluginList", () => {
  it("returns ordered settings plugins with enabled state", () => {
    const pluginSettings: PluginSettings = {
      order: ["codex", "missing", "cursor"],
      disabled: ["cursor"],
    }

    const { result } = renderHook(() =>
      useSettingsPluginList({
        pluginSettings,
        pluginsMeta: [
          createPluginMeta("cursor", "Cursor"),
          createPluginMeta("codex", "Codex"),
        ],
      })
    )

    expect(result.current).toEqual([
      { id: "codex", name: "Codex", enabled: true },
      { id: "cursor", name: "Cursor", enabled: false },
    ])
  })

  it("groups Codex account providers into one settings row", () => {
    const pluginSettings: PluginSettings = {
      order: ["codex", "codex-slot-account-2", "cursor"],
      disabled: ["codex-slot-account-2"],
    }

    const { result } = renderHook(() =>
      useSettingsPluginList({
        pluginSettings,
        pluginsMeta: [
          createPluginMeta("codex", "Codex"),
          createPluginMeta("codex-slot-account-2", "oscar@example.com"),
          createPluginMeta("cursor", "Cursor"),
        ],
      })
    )

    expect(result.current).toEqual([
      { id: "codex", name: "Codex", enabled: true },
      { id: "cursor", name: "Cursor", enabled: true },
    ])
  })

  it("marks grouped Codex disabled when all account providers are disabled", () => {
    const pluginSettings: PluginSettings = {
      order: ["codex", "codex-slot-account-2"],
      disabled: ["codex", "codex-slot-account-2"],
    }

    const { result } = renderHook(() =>
      useSettingsPluginList({
        pluginSettings,
        pluginsMeta: [
          createPluginMeta("codex", "Codex"),
          createPluginMeta("codex-slot-account-2", "oscar@example.com"),
        ],
      })
    )

    expect(result.current).toEqual([
      { id: "codex", name: "Codex", enabled: false },
    ])
  })

  it("returns empty list when settings are not loaded", () => {
    const { result } = renderHook(() =>
      useSettingsPluginList({
        pluginSettings: null,
        pluginsMeta: [createPluginMeta("codex", "Codex")],
      })
    )

    expect(result.current).toEqual([])
  })
})
