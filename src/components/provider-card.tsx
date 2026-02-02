import { useEffect, useState } from "react"
import { Hourglass, RefreshCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { Separator } from "@/components/ui/separator"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { SkeletonLines } from "@/components/skeleton-lines"
import { PluginError } from "@/components/plugin-error"
import { REFRESH_COOLDOWN_MS } from "@/lib/settings"
import type { ManifestLine, MetricLine } from "@/lib/plugin-types"

interface ProviderCardProps {
  name: string
  plan?: string
  showSeparator?: boolean
  loading?: boolean
  error?: string | null
  lines?: MetricLine[]
  skeletonLines?: ManifestLine[]
  lastManualRefreshAt?: number | null
  onRetry?: () => void
}

export function formatNumber(value: number) {
  if (Number.isNaN(value)) return "0"
  if (Number.isInteger(value)) return String(value)
  return value.toFixed(2)
}

export function formatProgressValue(value: number, unit?: "percent" | "dollars") {
  if (!Number.isFinite(value) || value < 0) {
    console.error("Invalid progress value:", value)
    return "N/A"
  }
  if (unit === "percent") {
    return `${Math.round(value)}%`
  }
  if (unit === "dollars") {
    return `$${formatNumber(value)}`
  }
  return formatNumber(value)
}

export function getProgressPercent(value: number, max: number) {
  if (!Number.isFinite(value) || !Number.isFinite(max) || max <= 0) return 0
  return Math.min(100, Math.max(0, (value / max) * 100))
}

export function ProviderCard({
  name,
  plan,
  showSeparator = true,
  loading = false,
  error = null,
  lines = [],
  skeletonLines = [],
  lastManualRefreshAt,
  onRetry,
}: ProviderCardProps) {
  const [now, setNow] = useState(Date.now())

  // Update "now" every second while in cooldown to keep UI in sync
  useEffect(() => {
    if (!lastManualRefreshAt) return
    const remaining = REFRESH_COOLDOWN_MS - (Date.now() - lastManualRefreshAt)
    if (remaining <= 0) return

    // Immediately sync "now" when entering cooldown
    setNow(Date.now())
    const interval = setInterval(() => setNow(Date.now()), 1000)
    // Auto-clear after cooldown expires
    const timeout = setTimeout(() => clearInterval(interval), remaining)

    return () => {
      clearInterval(interval)
      clearTimeout(timeout)
    }
  }, [lastManualRefreshAt])

  const inCooldown = lastManualRefreshAt ? now - lastManualRefreshAt < REFRESH_COOLDOWN_MS : false

  // Format remaining cooldown time as "Xm Ys"
  const formatRemainingTime = () => {
    if (!lastManualRefreshAt) return ""
    const remainingMs = REFRESH_COOLDOWN_MS - (now - lastManualRefreshAt)
    if (remainingMs <= 0) return ""
    const totalSeconds = Math.ceil(remainingMs / 1000)
    const minutes = Math.floor(totalSeconds / 60)
    const seconds = totalSeconds % 60
    if (minutes > 0) {
      return `Available in ${minutes}m ${seconds}s`
    }
    return `Available in ${seconds}s`
  }

  return (
    <div>
      <div className="py-3">
        <div className="flex items-center justify-between mb-2">
          <div className="relative flex items-center">
            <h2 className="text-lg font-semibold" style={{ transform: "translateZ(0)" }}>{name}</h2>
            {onRetry && (
              loading ? (
                <Button
                  variant="ghost"
                  size="icon-xs"
                  className="ml-1 pointer-events-none opacity-50"
                  style={{ transform: "translateZ(0)", backfaceVisibility: "hidden" }}
                  tabIndex={-1}
                >
                  <RefreshCw className="h-3 w-3 animate-spin" />
                </Button>
              ) : inCooldown ? (
                <Tooltip>
                  <TooltipTrigger
                    className="ml-1"
                    render={(props) => (
                      <span {...props} className={props.className}>
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          className="pointer-events-none opacity-50"
                          style={{ transform: "translateZ(0)", backfaceVisibility: "hidden" }}
                          tabIndex={-1}
                        >
                          <Hourglass className="h-3 w-3" />
                        </Button>
                      </span>
                    )}
                  />
                  <TooltipContent side="top">
                    {formatRemainingTime()}
                  </TooltipContent>
                </Tooltip>
              ) : (
                <Button
                  variant="ghost"
                  size="icon-xs"
                  aria-label="Retry"
                  onClick={(e) => {
                    e.currentTarget.blur()
                    onRetry()
                  }}
                  className="ml-1 opacity-0 hover:opacity-100 focus-visible:opacity-100"
                  style={{ transform: "translateZ(0)", backfaceVisibility: "hidden" }}
                >
                  <RefreshCw className="h-3 w-3" />
                </Button>
              )
            )}
          </div>
          {plan && (
            <Badge variant="outline" className="truncate min-w-0 max-w-[40%]" title={plan}>
              {plan}
            </Badge>
          )}
        </div>
        {error && <PluginError message={error} />}

        {loading && !error && (
          <SkeletonLines lines={skeletonLines} />
        )}

        {!loading && !error && (
          <div className="space-y-4">
            {lines.map((line, index) => (
              <MetricLineRenderer key={`${line.label}-${index}`} line={line} />
            ))}
          </div>
        )}
      </div>
      {showSeparator && <Separator />}
    </div>
  )
}

function MetricLineRenderer({ line }: { line: MetricLine }) {
  if (line.type === "text") {
    return (
      <div>
        <div className="flex justify-between items-center h-[22px]">
          <span className="text-sm text-muted-foreground flex-shrink-0">{line.label}</span>
          <span
            className="text-sm text-muted-foreground truncate min-w-0 max-w-[60%] text-right"
            style={line.color ? { color: line.color } : undefined}
            title={line.value}
          >
            {line.value}
          </span>
        </div>
        {line.subtitle && (
          <div className="text-xs text-muted-foreground text-right -mt-0.5">{line.subtitle}</div>
        )}
      </div>
    )
  }

  if (line.type === "badge") {
    return (
      <div>
        <div className="flex justify-between items-center h-[22px]">
          <span className="text-sm text-muted-foreground flex-shrink-0">{line.label}</span>
          <Badge
            variant="outline"
            className="truncate min-w-0 max-w-[60%]"
            style={
              line.color
                ? { color: line.color, borderColor: line.color }
                : undefined
            }
            title={line.text}
          >
            {line.text}
          </Badge>
        </div>
        {line.subtitle && (
          <div className="text-xs text-muted-foreground text-right -mt-0.5">{line.subtitle}</div>
        )}
      </div>
    )
  }

  if (line.type === "progress") {
    const percent = getProgressPercent(line.value, line.max)
    return (
      <div>
        <div className="text-sm font-medium mb-1.5">{line.label}</div>
        <Progress
          value={percent}
          indicatorColor={line.color}
        />
        <div className="flex justify-between items-center mt-1.5">
          <span className="text-xs text-muted-foreground tabular-nums">
            {formatProgressValue(line.value, line.unit)}
          </span>
          {line.subtitle && (
            <span className="text-xs text-muted-foreground">{line.subtitle}</span>
          )}
        </div>
      </div>
    )
  }

  return null
}
