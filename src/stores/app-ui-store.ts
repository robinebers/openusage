import { create } from "zustand"
import type { ActiveView } from "@/components/side-nav"

type AppUiStore = {
  activeView: ActiveView
  showAbout: boolean
  setActiveView: (view: ActiveView) => void
  setShowAbout: (value: boolean) => void
  resetState: () => void
}

const initialState = {
  activeView: "home" as ActiveView,
  showAbout: false,
}

export const useAppUiStore = create<AppUiStore>((set) => ({
  ...initialState,
  setActiveView: (view) => set({ activeView: view }),
  setShowAbout: (value) => set({ showAbout: value }),
  resetState: () => set(initialState),
}))
