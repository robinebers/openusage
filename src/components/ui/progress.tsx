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
          ? "translate(0, -50%)"
          : clampedMarker >= 100
            ? "translate(-100%, -50%)"
            : "translate(-50%, -50%)"
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
            className="absolute top-1/2 size-1.5 rounded-full z-10 pointer-events-none bg-primary border border-muted dark:border-[#353537]"
            style={markerStyle}
          />
        )}
      </div>
    )
  }
)
Progress.displayName = "Progress"

export { Progress }
