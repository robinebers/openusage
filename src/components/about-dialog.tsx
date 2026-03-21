import { useEffect, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { ChangelogDialog } from "./changelog-dialog";
import { Button } from "@/components/ui/button";

interface AboutDialogProps {
  version: string;
  onClose: () => void;
}

function ExternalLink({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  const handleClick = () => {
    openUrl(href).catch(console.error);
  };

  return (
    <button
      type="button"
      onClick={handleClick}
      className="text-primary hover:underline focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 rounded-sm"
    >
      {children}
    </button>
  );
}

export function AboutDialog({ version, onClose }: AboutDialogProps) {
  const [view, setView] = useState<"about" | "changelog">("about");

  // Close on ESC key
  useEffect(() => {
    if (view !== "about") {
      return;
    }

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [onClose, view]);

  // Close when panel hides (loses visibility)
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.hidden) {
        onClose();
      }
    };
    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => document.removeEventListener("visibilitychange", handleVisibilityChange);
  }, [onClose]);

  // Close on backdrop click
  const handleBackdropClick = (e: React.MouseEvent) => {
    if (e.target === e.currentTarget) {
      onClose();
    }
  };

  if (view === "changelog") {
    return (
      <ChangelogDialog
        currentVersion={version}
        onBack={() => setView("about")}
        // In changelog view, Escape should go back to About instead of
        // closing the entire dialog, so hand off to setView.
        onClose={() => setView("about")}
      />
    );
  }

  return (
    <div
      className="absolute inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm rounded-xl"
      onClick={handleBackdropClick}
    >
      <div className="bg-card rounded-lg border shadow-xl p-6 max-w-xs w-full mx-4 text-center animate-in fade-in zoom-in-95 duration-200">
        <img
          src="/icon.png"
          alt="OpenUsage"
          className="w-16 h-16 mx-auto mb-3 rounded-xl"
        />

        <h2 className="text-xl font-semibold mb-1">OpenUsage</h2>

        <div className="flex flex-col items-center gap-2 mb-4">
          <span className="inline-block text-xs text-muted-foreground bg-muted px-2 py-0.5 rounded-full">
            v{version}
          </span>
          <Button
            size="xs"
            variant="outline"
            onClick={() => setView("changelog")}
            className="text-[10px] h-5 px-1.5"
          >
            View Changelog
          </Button>
        </div>

        <div className="text-sm text-muted-foreground space-y-1">
          <p>
            Built by{" "}
            <ExternalLink href="https://itsbyrob.in/x">Robin Ebers</ExternalLink>
          </p>
          <p>
            Open source on{" "}
            <ExternalLink href="https://github.com/robinebers/openusage">
              GitHub
            </ExternalLink>
          </p>
          <p className="text-xs pt-1">
            Maintainers:{" "}
            <ExternalLink href="https://github.com/validatedev">
              validatedev
            </ExternalLink>
            ,{" "}
            <ExternalLink href="https://github.com/davidarny">
              davidarny
            </ExternalLink>
          </p>
        </div>
      </div>
    </div>
  );
}

