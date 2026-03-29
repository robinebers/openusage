import { describe, expect, it } from "vitest"
import type { PluginDisplayState, PluginMeta, PluginOutput } from "@/lib/plugin-types"
import {
  classifyWindowsProviderAvailability,
  getWindowsProviderAvailabilityNote,
} from "@/lib/windows-provider-support"

function makePluginState(overrides: Partial<PluginDisplayState> & { id?: string; name?: string } = {}): PluginDisplayState {
  const id = overrides.id ?? "claude"
  const name = overrides.name ?? "Claude"
  const meta: PluginMeta = {
    id,
    name,
    iconUrl: "icon.svg",
    lines: [],
    primaryCandidates: [],
  }
  const data: PluginOutput | null = overrides.data === undefined
    ? null
    : overrides.data

  return {
    meta,
    data,
    loading: false,
    error: null,
    lastManualRefreshAt: null,
    ...overrides,
  }
}

describe("windows provider support", () => {
  it("classifies v1 providers with data as ready", () => {
    const plugin = makePluginState({
      id: "claude",
      data: {
        providerId: "claude",
        displayName: "Claude",
        iconUrl: "icon.svg",
        lines: [{ type: "progress", label: "Session", used: 10, limit: 100, format: { kind: "percent" } }],
      },
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("ready")
    expect(getWindowsProviderAvailabilityNote(plugin)).toBeNull()
  })

  it("surfaces supported-but-not-detected messaging for v1 providers", () => {
    const plugin = makePluginState({
      id: "codex",
      name: "Codex",
      error: "Not logged in. Run `codex` to authenticate.",
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("not-detected")
    expect(getWindowsProviderAvailabilityNote(plugin)).toEqual(
      expect.objectContaining({
        kind: "not-detected",
        title: "Supported on Windows",
        suppressError: true,
      })
    )
  })

  it("treats Copilot as a supported Windows provider when auth is missing", () => {
    const plugin = makePluginState({
      id: "copilot",
      name: "Copilot",
      error: "Not logged in. Run `gh auth login` first.",
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("not-detected")
    expect(getWindowsProviderAvailabilityNote(plugin)).toEqual(
      expect.objectContaining({
        kind: "not-detected",
        title: "Supported on Windows",
        suppressError: true,
      })
    )
  })

  it("treats Windsurf as a supported Windows provider when local state is missing", () => {
    const plugin = makePluginState({
      id: "windsurf",
      name: "Windsurf",
      error: "Start Windsurf or sign in and try again.",
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("not-detected")
    expect(getWindowsProviderAvailabilityNote(plugin)).toEqual(
      expect.objectContaining({
        kind: "not-detected",
        title: "Supported on Windows",
        suppressError: true,
      })
    )
  })

  it("treats Antigravity as a supported Windows provider when local state is missing", () => {
    const plugin = makePluginState({
      id: "antigravity",
      name: "Antigravity",
      error: "Start Antigravity and try again.",
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("not-detected")
    expect(getWindowsProviderAvailabilityNote(plugin)).toEqual(
      expect.objectContaining({
        kind: "not-detected",
        title: "Supported on Windows",
        suppressError: true,
      })
    )
  })

  it("marks deferred providers as planned on Windows", () => {
    const plugin = makePluginState({
      id: "amp",
      name: "Amp",
      error: "Not logged in.",
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("planned")
    expect(getWindowsProviderAvailabilityNote(plugin)).toEqual(
      expect.objectContaining({
        kind: "planned",
        title: "Planned for Windows",
        suppressError: true,
      })
    )
  })

  it("marks blocked providers as not yet supported on Windows", () => {
    const plugin = makePluginState({
      id: "perplexity",
      name: "Perplexity",
      error: "Usage request failed.",
    })

    expect(classifyWindowsProviderAvailability(plugin)).toBe("blocked")
    expect(getWindowsProviderAvailabilityNote(plugin)).toEqual(
      expect.objectContaining({
        kind: "blocked",
        title: "Not yet supported on Windows",
        suppressError: true,
      })
    )
  })
})
