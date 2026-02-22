import { beforeEach, describe, expect, it } from "vitest"
import { useAppDerivedStore } from "@/stores/app-derived-store"

describe("useAppDerivedStore", () => {
  beforeEach(() => {
    useAppDerivedStore.getState().resetState()
  })

  it("updates plugin views without mutating other derived fields", () => {
    useAppDerivedStore.getState().setSettingsPlugins([
      { id: "codex", name: "Codex", enabled: true },
    ])
    useAppDerivedStore.getState().setAutoUpdateNextAt(12345)

    useAppDerivedStore.getState().setPluginViews({
      displayPlugins: [
        {
          meta: {
            id: "codex",
            name: "Codex",
            iconUrl: "/codex.svg",
            brandColor: "#000000",
            lines: [],
            primaryCandidates: [],
          },
          data: null,
          loading: false,
          error: null,
          lastManualRefreshAt: null,
        },
      ],
      navPlugins: [
        {
          id: "codex",
          name: "Codex",
          iconUrl: "/codex.svg",
          brandColor: "#000000",
        },
      ],
    })

    const state = useAppDerivedStore.getState()
    expect(state.displayPlugins).toHaveLength(1)
    expect(state.navPlugins).toHaveLength(1)
    expect(state.settingsPlugins).toEqual([
      { id: "codex", name: "Codex", enabled: true },
    ])
    expect(state.autoUpdateNextAt).toBe(12345)
  })
})
