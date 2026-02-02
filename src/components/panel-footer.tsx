import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import type { UpdateStatus } from "@/hooks/use-app-update";

interface PanelFooterProps {
  version: string;
  autoUpdateNextAt: number | null;
  updateStatus: UpdateStatus;
  onUpdateInstall: () => void;
}

function VersionDisplay({
  version,
  updateStatus,
  onUpdateInstall,
}: {
  version: string;
  updateStatus: UpdateStatus;
  onUpdateInstall: () => void;
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
      return (
        <span className="text-xs text-destructive" title={updateStatus.message}>
          Update failed
        </span>
      );
    default:
      return (
        <span className="text-xs text-muted-foreground">
          OpenUsage {version}
        </span>
      );
  }
}

export function PanelFooter({
  version,
  autoUpdateNextAt,
  updateStatus,
  onUpdateInstall,
}: PanelFooterProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!autoUpdateNextAt) return undefined;
    setNow(Date.now());
    const interval = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(interval);
  }, [autoUpdateNextAt]);

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
    <div className="flex justify-between items-center h-8 pt-1.5 border-t">
      <VersionDisplay
        version={version}
        updateStatus={updateStatus}
        onUpdateInstall={onUpdateInstall}
      />
      <span className="text-xs text-muted-foreground tabular-nums">
        {countdownLabel}
      </span>
    </div>
  );
}
