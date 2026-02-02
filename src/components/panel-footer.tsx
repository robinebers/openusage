import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { UpdateStatus } from "@/hooks/use-app-update";

interface PanelFooterProps {
  version: string;
  onRefresh: () => void;
  refreshDisabled?: boolean;
  updateStatus: UpdateStatus;
  onUpdateDownload: () => void;
  onUpdateInstall: () => void;
}

function VersionDisplay({
  version,
  updateStatus,
  onUpdateDownload,
  onUpdateInstall,
}: {
  version: string;
  updateStatus: UpdateStatus;
  onUpdateDownload: () => void;
  onUpdateInstall: () => void;
}) {
  switch (updateStatus.status) {
    case "available":
      return (
        <button
          type="button"
          onClick={onUpdateDownload}
          className="text-xs text-primary hover:underline underline-offset-4 bg-transparent border-none p-0 cursor-pointer"
        >
          v{updateStatus.version} available
        </button>
      );
    case "downloading":
      return (
        <span className="text-xs text-muted-foreground">
          {updateStatus.progress >= 0
            ? `Downloading... ${updateStatus.progress}%`
            : "Downloading..."}
        </span>
      );
    case "ready":
      return (
        <button
          type="button"
          onClick={onUpdateInstall}
          className="text-xs text-primary hover:underline underline-offset-4 bg-transparent border-none p-0 cursor-pointer"
        >
          Restart to update
        </button>
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
  onRefresh,
  refreshDisabled,
  updateStatus,
  onUpdateDownload,
  onUpdateInstall,
}: PanelFooterProps) {
  return (
    <div className="flex justify-between items-center pt-1.5 border-t">
      <VersionDisplay
        version={version}
        updateStatus={updateStatus}
        onUpdateDownload={onUpdateDownload}
        onUpdateInstall={onUpdateInstall}
      />
      {refreshDisabled ? (
        <Tooltip>
          <TooltipTrigger
            render={(props) => (
              <span {...props}>
                <Button
                  variant="link"
                  size="sm"
                  className="px-0 text-xs pointer-events-none opacity-50"
                  tabIndex={-1}
                >
                  Refresh all
                </Button>
              </span>
            )}
          />
          <TooltipContent side="top">
            All plugins recently refreshed
          </TooltipContent>
        </Tooltip>
      ) : (
        <Button
          variant="link"
          size="sm"
          onClick={onRefresh}
          className="px-0 text-xs"
        >
          Refresh all
        </Button>
      )}
    </div>
  );
}
