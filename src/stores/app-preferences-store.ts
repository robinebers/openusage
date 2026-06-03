import { create } from "zustand"
import {
  DEFAULT_AUTO_UPDATE_INTERVAL,
  DEFAULT_DISPLAY_MODE,
  DEFAULT_ALWAYS_ON_TOP,
  DEFAULT_GLOBAL_SHORTCUT,
  DEFAULT_HIDE_DOCK_ICON,
  DEFAULT_MENUBAR_ICON_STYLE,
  DEFAULT_RESET_TIMER_DISPLAY_MODE,
  DEFAULT_START_ON_LOGIN,
  DEFAULT_THEME_MODE,
  DEFAULT_TIME_FORMAT_MODE,
  type AutoUpdateIntervalMinutes,
  type DisplayMode,
  type GlobalShortcut,
  type MenubarIconStyle,
  type ResetTimerDisplayMode,
  type ThemeMode,
  type TimeFormatMode,
} from "@/lib/settings"

type AppPreferencesStore = {
  autoUpdateInterval: AutoUpdateIntervalMinutes
  themeMode: ThemeMode
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  timeFormatMode: TimeFormatMode
  globalShortcut: GlobalShortcut
  startOnLogin: boolean
  hideDockIcon: boolean
  alwaysOnTop: boolean
  menubarIconStyle: MenubarIconStyle
  setAutoUpdateInterval: (value: AutoUpdateIntervalMinutes) => void
  setThemeMode: (value: ThemeMode) => void
  setDisplayMode: (value: DisplayMode) => void
  setResetTimerDisplayMode: (value: ResetTimerDisplayMode) => void
  setTimeFormatMode: (value: TimeFormatMode) => void
  setGlobalShortcut: (value: GlobalShortcut) => void
  setStartOnLogin: (value: boolean) => void
  setHideDockIcon: (value: boolean) => void
  setAlwaysOnTop: (value: boolean) => void
  setMenubarIconStyle: (value: MenubarIconStyle) => void
  resetState: () => void
}

const initialState = {
  autoUpdateInterval: DEFAULT_AUTO_UPDATE_INTERVAL,
  themeMode: DEFAULT_THEME_MODE,
  displayMode: DEFAULT_DISPLAY_MODE,
  resetTimerDisplayMode: DEFAULT_RESET_TIMER_DISPLAY_MODE,
  timeFormatMode: DEFAULT_TIME_FORMAT_MODE,
  globalShortcut: DEFAULT_GLOBAL_SHORTCUT,
  startOnLogin: DEFAULT_START_ON_LOGIN,
  hideDockIcon: DEFAULT_HIDE_DOCK_ICON,
  alwaysOnTop: DEFAULT_ALWAYS_ON_TOP,
  menubarIconStyle: DEFAULT_MENUBAR_ICON_STYLE,
}

export const useAppPreferencesStore = create<AppPreferencesStore>((set) => ({
  ...initialState,
  setAutoUpdateInterval: (value) => set({ autoUpdateInterval: value }),
  setThemeMode: (value) => set({ themeMode: value }),
  setDisplayMode: (value) => set({ displayMode: value }),
  setResetTimerDisplayMode: (value) => set({ resetTimerDisplayMode: value }),
  setTimeFormatMode: (value) => set({ timeFormatMode: value }),
  setGlobalShortcut: (value) => set({ globalShortcut: value }),
  setStartOnLogin: (value) => set({ startOnLogin: value }),
  setHideDockIcon: (value) => set({ hideDockIcon: value }),
  setAlwaysOnTop: (value) => set({ alwaysOnTop: value }),
  setMenubarIconStyle: (value) => set({ menubarIconStyle: value }),
  resetState: () => set(initialState),
}))
