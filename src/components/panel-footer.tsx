import { useMemo } from "react";
import { Button } from "@/components/ui/button";
import { AboutDialog } from "@/components/about-dialog";
import type { UpdateStatus } from "@/hooks/use-app-update";
import { useNowTicker } from "@/hooks/use-now-ticker";

interface PanelFooterProps {
  version: string;
  autoUpdateNextAt: number | null;
  updateStatus: UpdateStatus;
  onUpdateInstall: () => void;
  onUpdateCheck: () => void;
  onRefreshAll?: () => void;
  showAbout: boolean;
  onShowAbout: () => void;
  onCloseAbout: () => void;
}

function VersionDisplay({
  version,
  updateStatus,
  onUpdateInstall,
  onUpdateCheck,
  onVersionClick,
}: {
  version: string;
  updateStatus: UpdateStatus;
  onUpdateInstall: () => void;
  onUpdateCheck: () => void;
  onVersionClick: () => void;
}) {
  switch (updateStatus.status) {
    case "downloading":
      return (
        <span className="text-xs text-muted-foreground">
          {updateStatus.progress >= 0
            ? `Downloading update ${updateStatus.progress}%`
            : "Downloading update..."}
        </span>
      );
    case "ready":
      return (
        <Button
          variant="destructive"
          size="xs"
          className="update-border-beam"
          onClick={onUpdateInstall}
        >
          Restart to update
        </Button>
      );
    case "installing":
      return (
        <span className="text-xs text-muted-foreground">Installing...</span>
      );
    case "error":
      if (updateStatus.message === "Update check failed") {
        return (
          <button
            type="button"
            onClick={onUpdateCheck}
            className="text-xs text-muted-foreground hover:text-foreground transition-colors cursor-pointer"
            title={updateStatus.message}
          >
            Updates soon
          </button>
        );
      }
      return (
        <span className="text-xs text-destructive" title={updateStatus.message}>
          Update failed
        </span>
      );
    default:
      return (
        <button
          type="button"
          onClick={onVersionClick}
          className="text-xs text-muted-foreground hover:text-foreground transition-colors cursor-pointer"
        >
          OpenUsage {version}
        </button>
      );
  }
}

export function PanelFooter({
  version,
  autoUpdateNextAt,
  updateStatus,
  onUpdateInstall,
  onUpdateCheck,
  onRefreshAll,
  showAbout,
  onShowAbout,
  onCloseAbout,
}: PanelFooterProps) {
  const now = useNowTicker({
    enabled: Boolean(autoUpdateNextAt),
    resetKey: autoUpdateNextAt,
  });

  const countdownLabel = useMemo(() => {
    if (!autoUpdateNextAt) return "Paused";
    const remainingMs = Math.max(0, autoUpdateNextAt - now);
    const totalSeconds = Math.ceil(remainingMs / 1000);
    if (totalSeconds >= 60) {
      const minutes = Math.ceil(totalSeconds / 60);
      return `Next update in ${minutes}m`;
    }
    return `Next update in ${totalSeconds}s`;
  }, [autoUpdateNextAt, now]);

  return (
    <>
      <div className="flex justify-between items-center h-8 pt-1.5 border-t">
        <VersionDisplay
          version={version}
          updateStatus={updateStatus}
          onUpdateInstall={onUpdateInstall}
          onUpdateCheck={onUpdateCheck}
          onVersionClick={onShowAbout}
        />
        {autoUpdateNextAt !== null && onRefreshAll ? (
          <button
            type="button"
            onClick={(event) => {
              event.currentTarget.blur()
              onRefreshAll()
            }}
            className="text-xs text-muted-foreground tabular-nums hover:text-foreground transition-colors cursor-pointer"
            title="Refresh now"
          >
            {countdownLabel}
          </button>
        ) : (
          <span className="text-xs text-muted-foreground tabular-nums">
            {countdownLabel}
          </span>
        )}
      </div>
      {showAbout && (
        <AboutDialog version={version} onClose={onCloseAbout} />
      )}
    </>
  );
}
