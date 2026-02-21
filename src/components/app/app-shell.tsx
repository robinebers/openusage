import { useShallow } from "zustand/react/shallow"
import { AppContent, type AppContentProps } from "@/components/app/app-content"
import { PanelFooter } from "@/components/panel-footer"
import { SideNav } from "@/components/side-nav"
import { useAppVersion } from "@/hooks/app/use-app-version"
import { usePanel } from "@/hooks/app/use-panel"
import { useAppUpdate } from "@/hooks/use-app-update"
import { useAppDerivedStore } from "@/stores/app-derived-store"
import { useAppUiStore } from "@/stores/app-ui-store"

const ARROW_OVERHEAD_PX = 37

type AppShellProps = {
  onRefreshAll: () => void
  appContentProps: AppContentProps
}

export function AppShell({ onRefreshAll, appContentProps }: AppShellProps) {
  const {
    activeView,
    setActiveView,
    showAbout,
    setShowAbout,
  } = useAppUiStore(
    useShallow((state) => ({
      activeView: state.activeView,
      setActiveView: state.setActiveView,
      showAbout: state.showAbout,
      setShowAbout: state.setShowAbout,
    }))
  )

  const {
    navPlugins,
    displayPlugins,
    autoUpdateNextAt,
  } = useAppDerivedStore(
    useShallow((state) => ({
      navPlugins: state.navPlugins,
      displayPlugins: state.displayPlugins,
      autoUpdateNextAt: state.autoUpdateNextAt,
    }))
  )

  const {
    containerRef,
    scrollRef,
    canScrollDown,
    maxPanelHeightPx,
  } = usePanel({
    activeView,
    setActiveView,
    showAbout,
    setShowAbout,
    displayPlugins,
  })

  const appVersion = useAppVersion()
  const { updateStatus, triggerInstall, checkForUpdates } = useAppUpdate()

  return (
    <div ref={containerRef} className="flex flex-col items-center p-6 pt-1.5 bg-transparent">
      <div className="tray-arrow" />
      <div
        className="relative bg-card rounded-xl overflow-hidden select-none w-full border shadow-lg flex flex-col"
        style={maxPanelHeightPx ? { maxHeight: `${maxPanelHeightPx - ARROW_OVERHEAD_PX}px` } : undefined}
      >
        <div className="flex flex-1 min-h-0 flex-row">
          <SideNav
            activeView={activeView}
            onViewChange={setActiveView}
            plugins={navPlugins}
          />
          <div className="flex-1 flex flex-col px-3 pt-2 pb-1.5 min-w-0 bg-card dark:bg-muted/50">
            <div className="relative flex-1 min-h-0">
              <div ref={scrollRef} className="h-full overflow-y-auto scrollbar-none">
                <AppContent {...appContentProps} />
              </div>
              <div
                className={`pointer-events-none absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-card dark:from-muted/50 to-transparent transition-opacity duration-200 ${canScrollDown ? "opacity-100" : "opacity-0"}`}
              />
            </div>
            <PanelFooter
              version={appVersion}
              autoUpdateNextAt={autoUpdateNextAt}
              updateStatus={updateStatus}
              onUpdateInstall={triggerInstall}
              onUpdateCheck={checkForUpdates}
              onRefreshAll={onRefreshAll}
              showAbout={showAbout}
              onShowAbout={() => setShowAbout(true)}
              onCloseAbout={() => setShowAbout(false)}
            />
          </div>
        </div>
      </div>
    </div>
  )
}
