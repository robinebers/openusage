import * as React from "react"

import { cn } from "@/lib/utils"

interface ProgressProps extends React.HTMLAttributes<HTMLDivElement> {
  value?: number
  indicatorColor?: string
}

const Progress = React.forwardRef<HTMLDivElement, ProgressProps>(
  ({ className, value = 0, indicatorColor, ...props }, ref) => {
    const clamped = Math.min(100, Math.max(0, value))
    const indicatorStyle = indicatorColor
      ? { backgroundColor: indicatorColor }
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
      </div>
    )
  }
)
Progress.displayName = "Progress"

export { Progress }
