import * as React from "react"

import { cn } from "@/lib/utils"

interface ProgressProps extends React.HTMLAttributes<HTMLDivElement> {
  value?: number
  indicatorColor?: string
  markerValue?: number
}

const Progress = React.forwardRef<HTMLDivElement, ProgressProps>(
  ({ className, value = 0, indicatorColor, markerValue, ...props }, ref) => {
    const clamped = Math.min(100, Math.max(0, value))
    const clampedMarker =
      typeof markerValue === "number" && Number.isFinite(markerValue)
        ? Math.min(100, Math.max(0, markerValue))
        : null
    const showMarker = clampedMarker !== null && clamped > 0 && clamped < 100
    const indicatorStyle = indicatorColor
      ? { backgroundColor: indicatorColor }
      : undefined
    const markerTransform =
      clampedMarker === null
        ? undefined
        : clampedMarker <= 0
          ? "translateX(0)"
          : clampedMarker >= 100
            ? "translateX(-100%)"
            : "translateX(-50%)"
    const markerStyle = showMarker
      ? {
          left: `${clampedMarker}%`,
          transform: markerTransform,
        }
      : undefined

    return (
      <div
        ref={ref}
        role="progressbar"
        aria-valuenow={clamped}
        aria-valuemin={0}
        aria-valuemax={100}
        className={cn("relative h-3 w-full overflow-hidden rounded-full bg-muted dark:bg-[#353537]", className)}
        {...props}
      >
        <div
          className="h-full transition-all bg-primary"
          style={{ width: `${clamped}%`, ...indicatorStyle }}
        />
        {showMarker && (
          <div
            data-slot="progress-marker"
            aria-hidden="true"
            className="absolute top-0 bottom-0 w-[2px] z-10 pointer-events-none bg-muted-foreground opacity-50"
            style={markerStyle}
          />
        )}
      </div>
    )
  }
)
Progress.displayName = "Progress"

export { Progress }
