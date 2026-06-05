import { Button } from "@/components/ui/button";
import { MENUBAR_ICON_STYLE_OPTIONS, type MenubarIconStyle } from "@/lib/settings";
import { getBarFillLayout, getTrayIconSizePx } from "@/lib/tray-bars-icon";
import type { TraySettingsPreview } from "@/hooks/app/use-tray-icon";
import { cn } from "@/lib/utils";

const TRAY_PREVIEW_SIZE_PX = getTrayIconSizePx(1);
const PREVIEW_BAR_TRACK_PX = 20;

function getPreviewBarLayout(fraction: number): { fillPercent: number; remainderPercent: number } {
  const { fillW, remainderDrawW } = getBarFillLayout(PREVIEW_BAR_TRACK_PX, fraction);
  return {
    fillPercent: (fillW / PREVIEW_BAR_TRACK_PX) * 100,
    remainderPercent: (remainderDrawW / PREVIEW_BAR_TRACK_PX) * 100,
  };
}

function ProviderIconMask({
  iconUrl,
  isActive,
  sizePx,
}: {
  iconUrl?: string;
  isActive: boolean;
  sizePx: number;
}) {
  const colorClass = isActive ? "bg-primary-foreground" : "bg-foreground";
  if (iconUrl) {
    return (
      <div
        aria-hidden
        className={cn("shrink-0", colorClass)}
        style={{
          width: `${sizePx}px`,
          height: `${sizePx}px`,
          WebkitMaskImage: `url(${iconUrl})`,
          WebkitMaskSize: "contain",
          WebkitMaskRepeat: "no-repeat",
          WebkitMaskPosition: "center",
          maskImage: `url(${iconUrl})`,
          maskSize: "contain",
          maskRepeat: "no-repeat",
          maskPosition: "center",
        }}
      />
    );
  }
  const textClass = isActive ? "text-primary-foreground" : "text-foreground";
  return (
    <svg aria-hidden viewBox="0 0 26 26" className={cn("shrink-0", textClass)} style={{ width: `${sizePx}px`, height: `${sizePx}px` }}>
      <circle cx="13" cy="13" r="9" fill="none" stroke="currentColor" strokeWidth="3.5" opacity={0.3} />
    </svg>
  );
}

function MenubarIconStylePreview({
  style,
  isActive,
  traySettingsPreview,
}: {
  style: MenubarIconStyle;
  isActive: boolean;
  traySettingsPreview: TraySettingsPreview;
}) {
  const textClass = isActive ? "text-primary-foreground" : "text-foreground";

  if (style === "provider") {
    return (
      <div className="inline-flex items-center gap-0.5">
        <ProviderIconMask iconUrl={traySettingsPreview.providerIconUrl} isActive={isActive} sizePx={TRAY_PREVIEW_SIZE_PX} />
        <span className={cn("text-[12px] font-semibold tabular-nums leading-none", textClass)}>
          {traySettingsPreview.providerPercentText}
        </span>
      </div>
    );
  }

  if (style === "bars") {
    const trackClass = isActive ? "bg-primary-foreground/15" : "bg-foreground/15";
    const remainderClass = isActive ? "bg-primary-foreground/20" : "bg-foreground/15";
    const fillClass = isActive ? "bg-primary-foreground" : "bg-foreground";
    const fractions = traySettingsPreview.bars.length > 0
      ? traySettingsPreview.bars.map((b) => b.fraction ?? 0)
      : [0.83, 0.7, 0.56];

    return (
      <div className="flex items-center">
        <div className="flex flex-col gap-0.5 w-5">
          {fractions.map((fraction, i) => {
            const { fillPercent, remainderPercent } = getPreviewBarLayout(fraction);
            return (
              <div key={i} className={cn("relative h-1 rounded-sm", trackClass)}>
                {remainderPercent > 0 && (
                  <span
                    aria-hidden
                    className={remainderClass}
                    style={{
                      position: "absolute",
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: `${remainderPercent}%`,
                      borderRadius: "1px 2px 2px 1px",
                    }}
                  />
                )}
                <div className={cn("h-1", fillClass)} style={{ width: `${fillPercent}%`, borderRadius: "2px 1px 1px 2px" }} />
              </div>
            );
          })}
        </div>
      </div>
    );
  }

  if (style === "donut") {
    const fraction = traySettingsPreview.providerBars[0]?.fraction ?? 0;
    const clamped = Math.max(0, Math.min(1, fraction));
    return (
      <div className="inline-flex items-center gap-1">
        <ProviderIconMask iconUrl={traySettingsPreview.providerIconUrl} isActive={isActive} sizePx={TRAY_PREVIEW_SIZE_PX} />
        <svg aria-hidden viewBox="0 0 26 26" className={cn("shrink-0", textClass)} style={{ width: `${TRAY_PREVIEW_SIZE_PX}px`, height: `${TRAY_PREVIEW_SIZE_PX}px` }}>
          <circle cx="13" cy="13" r="9" fill="none" stroke="currentColor" strokeWidth="4" opacity={isActive ? 0.2 : 0.15} />
          {clamped > 0 && (
            <circle
              cx="13" cy="13" r="9"
              fill="none" stroke="currentColor" strokeWidth="4"
              strokeLinecap="butt"
              pathLength="100"
              strokeDasharray={`${Math.round(clamped * 100)} 100`}
              transform="rotate(-90 13 13)"
            />
          )}
        </svg>
      </div>
    );
  }

  return null;
}

export function MenubarIconStyleSection({
  menubarIconStyle,
  traySettingsPreview,
  onMenubarIconStyleChange,
}: {
  menubarIconStyle: MenubarIconStyle;
  traySettingsPreview: TraySettingsPreview;
  onMenubarIconStyleChange: (value: MenubarIconStyle) => void;
}) {
  return (
    <section>
      <h3 className="text-lg font-semibold mb-0">Menubar Icon</h3>
      <p className="text-sm text-muted-foreground mb-2">
        What shows in the menu bar
      </p>
      <div className="bg-muted/50 rounded-lg p-1">
        <div className="flex gap-1" role="radiogroup" aria-label="Menubar icon style">
          {MENUBAR_ICON_STYLE_OPTIONS.map((option) => {
            const isActive = option.value === menubarIconStyle;
            return (
              <Button
                key={option.value}
                type="button"
                role="radio"
                aria-label={option.label}
                aria-checked={isActive}
                variant={isActive ? "default" : "outline"}
                size="sm"
                className="flex-1 h-9 flex items-center justify-center"
                onClick={() => onMenubarIconStyleChange(option.value)}
              >
                <MenubarIconStylePreview
                  style={option.value}
                  isActive={isActive}
                  traySettingsPreview={traySettingsPreview}
                />
              </Button>
            );
          })}
        </div>
      </div>
    </section>
  );
}
