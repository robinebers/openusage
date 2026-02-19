import { beforeEach, describe, expect, it, vi } from "vitest"
import {
  DEFAULT_AUTO_UPDATE_INTERVAL,
  DEFAULT_CLI_PROMPT_DECISION,
  DEFAULT_DISPLAY_MODE,
  DEFAULT_PLUGIN_SETTINGS,
  DEFAULT_RESET_TIMER_DISPLAY_MODE,
  DEFAULT_START_ON_LOGIN,
  DEFAULT_TRAY_ICON_STYLE,
  DEFAULT_TRAY_SHOW_PERCENTAGE,
  DEFAULT_THEME_MODE,
  arePluginSettingsEqual,
  getEnabledPluginIds,
  loadAutoUpdateInterval,
  loadCliPromptDecision,
  loadDisplayMode,
  loadPluginSettings,
  loadResetTimerDisplayMode,
  loadStartOnLogin,
  loadTrayIconStyle,
  loadTrayShowPercentage,
  loadThemeMode,
  normalizePluginSettings,
  saveAutoUpdateInterval,
  saveCliPromptDecision,
  saveDisplayMode,
  savePluginSettings,
  saveResetTimerDisplayMode,
  saveStartOnLogin,
  saveTrayIconStyle,
  saveTrayShowPercentage,
  saveThemeMode,
} from "@/lib/settings"
import type { PluginMeta } from "@/lib/plugin-types"

const storeState = new Map<string, unknown>()

vi.mock("@tauri-apps/plugin-store", () => ({
  LazyStore: class {
    async get<T>(key: string): Promise<T | null> {
      return (storeState.get(key) as T | undefined) ?? null
    }
    async set<T>(key: string, value: T): Promise<void> {
      storeState.set(key, value)
    }
    async save(): Promise<void> {}
  },
}))

describe("settings", () => {
  beforeEach(() => {
    storeState.clear()
  })

  it("loads defaults when no settings stored", async () => {
    await expect(loadPluginSettings()).resolves.toEqual(DEFAULT_PLUGIN_SETTINGS)
  })

  it("sanitizes stored settings", async () => {
    storeState.set("plugins", { order: ["a"], disabled: "nope" })
    await expect(loadPluginSettings()).resolves.toEqual({
      order: ["a"],
      disabled: [],
    })
  })

  it("saves settings", async () => {
    const settings = { order: ["a"], disabled: ["b"] }
    await savePluginSettings(settings)
    await expect(loadPluginSettings()).resolves.toEqual(settings)
  })

  it("normalizes order + disabled against known plugins", () => {
    const plugins: PluginMeta[] = [
      { id: "a", name: "A", iconUrl: "", lines: [] },
      { id: "b", name: "B", iconUrl: "", lines: [] },
    ]
    const normalized = normalizePluginSettings(
      { order: ["b", "b", "c"], disabled: ["c", "a"] },
      plugins
    )
    expect(normalized).toEqual({ order: ["b", "a"], disabled: ["a"] })
  })

  it("auto-disables new non-default plugins", () => {
    const plugins: PluginMeta[] = [
      { id: "claude", name: "Claude", iconUrl: "", lines: [], primaryCandidates: [] },
      { id: "copilot", name: "Copilot", iconUrl: "", lines: [], primaryCandidates: [] },
      { id: "windsurf", name: "Windsurf", iconUrl: "", lines: [], primaryCandidates: [] },
    ]
    const result = normalizePluginSettings({ order: [], disabled: [] }, plugins)
    expect(result.order).toEqual(["claude", "copilot", "windsurf"])
    expect(result.disabled).toEqual(["copilot", "windsurf"])
  })

  it("compares settings equality", () => {
    const a = { order: ["a"], disabled: [] }
    const b = { order: ["a"], disabled: [] }
    const c = { order: ["b"], disabled: [] }
    expect(arePluginSettingsEqual(a, b)).toBe(true)
    expect(arePluginSettingsEqual(a, c)).toBe(false)
  })

  it("returns enabled plugin ids", () => {
    expect(getEnabledPluginIds({ order: ["a", "b"], disabled: ["b"] })).toEqual(["a"])
  })

  it("loads default auto-update interval when missing", async () => {
    await expect(loadAutoUpdateInterval()).resolves.toBe(DEFAULT_AUTO_UPDATE_INTERVAL)
  })

  it("loads stored auto-update interval", async () => {
    storeState.set("autoUpdateInterval", 30)
    await expect(loadAutoUpdateInterval()).resolves.toBe(30)
  })

  it("saves auto-update interval", async () => {
    await saveAutoUpdateInterval(5)
    await expect(loadAutoUpdateInterval()).resolves.toBe(5)
  })

  it("loads default theme mode when missing", async () => {
    await expect(loadThemeMode()).resolves.toBe(DEFAULT_THEME_MODE)
  })

  it("loads stored theme mode", async () => {
    storeState.set("themeMode", "dark")
    await expect(loadThemeMode()).resolves.toBe("dark")
  })

  it("saves theme mode", async () => {
    await saveThemeMode("light")
    await expect(loadThemeMode()).resolves.toBe("light")
  })

  it("falls back to default for invalid theme mode", async () => {
    storeState.set("themeMode", "invalid")
    await expect(loadThemeMode()).resolves.toBe(DEFAULT_THEME_MODE)
  })

  it("loads default display mode when missing", async () => {
    await expect(loadDisplayMode()).resolves.toBe(DEFAULT_DISPLAY_MODE)
  })

  it("loads stored display mode", async () => {
    storeState.set("displayMode", "left")
    await expect(loadDisplayMode()).resolves.toBe("left")
  })

  it("saves display mode", async () => {
    await saveDisplayMode("left")
    await expect(loadDisplayMode()).resolves.toBe("left")
  })

  it("falls back to default for invalid display mode", async () => {
    storeState.set("displayMode", "invalid")
    await expect(loadDisplayMode()).resolves.toBe(DEFAULT_DISPLAY_MODE)
  })

  it("loads default reset timer display mode when missing", async () => {
    await expect(loadResetTimerDisplayMode()).resolves.toBe(DEFAULT_RESET_TIMER_DISPLAY_MODE)
  })

  it("loads stored reset timer display mode", async () => {
    storeState.set("resetTimerDisplayMode", "absolute")
    await expect(loadResetTimerDisplayMode()).resolves.toBe("absolute")
  })

  it("saves reset timer display mode", async () => {
    await saveResetTimerDisplayMode("relative")
    await expect(loadResetTimerDisplayMode()).resolves.toBe("relative")
  })

  it("falls back to default for invalid reset timer display mode", async () => {
    storeState.set("resetTimerDisplayMode", "invalid")
    await expect(loadResetTimerDisplayMode()).resolves.toBe(DEFAULT_RESET_TIMER_DISPLAY_MODE)
  })

  it("loads default tray icon style when missing", async () => {
    await expect(loadTrayIconStyle()).resolves.toBe(DEFAULT_TRAY_ICON_STYLE)
  })

  it("loads stored tray icon style", async () => {
    storeState.set("trayIconStyle", "circle")
    await expect(loadTrayIconStyle()).resolves.toBe("circle")
  })

  it("loads stored provider tray icon style", async () => {
    storeState.set("trayIconStyle", "provider")
    await expect(loadTrayIconStyle()).resolves.toBe("provider")
  })

  it("saves tray icon style", async () => {
    await saveTrayIconStyle("textOnly")
    await expect(loadTrayIconStyle()).resolves.toBe("textOnly")
  })

  it("saves provider tray icon style", async () => {
    await saveTrayIconStyle("provider")
    await expect(loadTrayIconStyle()).resolves.toBe("provider")
  })

  it("falls back to default for invalid tray icon style", async () => {
    storeState.set("trayIconStyle", "invalid")
    await expect(loadTrayIconStyle()).resolves.toBe(DEFAULT_TRAY_ICON_STYLE)
  })

  it("loads default tray show percentage when missing", async () => {
    await expect(loadTrayShowPercentage()).resolves.toBe(DEFAULT_TRAY_SHOW_PERCENTAGE)
  })

  it("loads stored tray show percentage", async () => {
    storeState.set("trayShowPercentage", true)
    await expect(loadTrayShowPercentage()).resolves.toBe(true)
  })

  it("saves tray show percentage", async () => {
    await saveTrayShowPercentage(true)
    await expect(loadTrayShowPercentage()).resolves.toBe(true)
  })

  it("falls back to default for invalid tray show percentage", async () => {
    storeState.set("trayShowPercentage", "invalid")
    await expect(loadTrayShowPercentage()).resolves.toBe(DEFAULT_TRAY_SHOW_PERCENTAGE)
  })

  it("loads default start on login when missing", async () => {
    await expect(loadStartOnLogin()).resolves.toBe(DEFAULT_START_ON_LOGIN)
  })

  it("loads stored start on login value", async () => {
    storeState.set("startOnLogin", true)
    await expect(loadStartOnLogin()).resolves.toBe(true)
  })

  it("saves start on login value", async () => {
    await saveStartOnLogin(true)
    await expect(loadStartOnLogin()).resolves.toBe(true)
  })

  it("falls back to default for invalid start on login value", async () => {
    storeState.set("startOnLogin", "invalid")
    await expect(loadStartOnLogin()).resolves.toBe(DEFAULT_START_ON_LOGIN)
  })

  it("loads default CLI prompt decision when missing", async () => {
    await expect(loadCliPromptDecision()).resolves.toBe(DEFAULT_CLI_PROMPT_DECISION)
  })

  it("loads stored CLI prompt decision", async () => {
    storeState.set("cliPromptDecision", "dismissed")
    await expect(loadCliPromptDecision()).resolves.toBe("dismissed")
  })

  it("saves CLI prompt decision", async () => {
    await saveCliPromptDecision("installed")
    await expect(loadCliPromptDecision()).resolves.toBe("installed")
  })
})
