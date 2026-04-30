import { create } from "zustand"
import type { ActiveView } from "@/components/side-nav"

type AppUiStore = {
  activeView: ActiveView
  showAbout: boolean
  selectedCodexProviderId: string | null
  setActiveView: (view: ActiveView) => void
  setShowAbout: (value: boolean) => void
  setSelectedCodexProviderId: (value: string) => void
  resetState: () => void
}

const initialState = {
  activeView: "home" as ActiveView,
  showAbout: false,
  selectedCodexProviderId: null as string | null,
}

export const useAppUiStore = create<AppUiStore>((set) => ({
  ...initialState,
  setActiveView: (view) => set({ activeView: view }),
  setShowAbout: (value) => set({ showAbout: value }),
  setSelectedCodexProviderId: (value) => set({ selectedCodexProviderId: value }),
  resetState: () => set(initialState),
}))
