import { useMemo } from "react"
import { Hourglass, RefreshCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { Separator } from "@/components/ui/separator"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { SkeletonLines } from "@/components/skeleton-lines"
import { PluginError } from "@/components/plugin-error"
import { useNowTicker } from "@/hooks/use-now-ticker"
import { REFRESH_COOLDOWN_MS, type DisplayMode } from "@/lib/settings"
import type { ManifestLine, MetricLine } from "@/lib/plugin-types"
import { clamp01 } from "@/lib/utils"
import { calculatePaceStatus, type PaceStatus } from "@/lib/pace-status"

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
  scopeFilter?: "overview" | "all"
  displayMode: DisplayMode
}

export function formatNumber(value: number) {
  if (Number.isNaN(value)) return "0"
  const fractionDigits = Number.isInteger(value) ? 0 : 2
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
  }).format(value)
}

function formatCount(value: number) {
  if (!Number.isFinite(value)) return "0"
  const maximumFractionDigits = Number.isInteger(value) ? 0 : 2
  return new Intl.NumberFormat("en-US", { maximumFractionDigits }).format(value)
}

function formatResetIn(nowMs: number, resetsAtIso: string): string | null {
  const resetsAtMs = Date.parse(resetsAtIso)
  if (!Number.isFinite(resetsAtMs)) return null
  const deltaMs = resetsAtMs - nowMs
  if (deltaMs <= 0) return "Resets now"

  const totalSeconds = Math.floor(deltaMs / 1000)
  const totalMinutes = Math.floor(totalSeconds / 60)
  const totalHours = Math.floor(totalMinutes / 60)
  const days = Math.floor(totalHours / 24)
  const hours = totalHours % 24
  const minutes = totalMinutes % 60

  if (days > 0) return `Resets in ${days}d ${hours}h`
  if (totalHours > 0) return `Resets in ${totalHours}h ${minutes}m`
  if (totalMinutes > 0) return `Resets in ${totalMinutes}m`
  return "Resets in <1m"
}

/** Colored dot indicator showing pace status */
function getPaceStatusText(status: PaceStatus): string {
  return status === "ahead" ? "Ahead of pace" : status === "on-track" ? "On track" : "Using fast"
}

function formatCompactDuration(deltaMs: number): string | null {
  if (!Number.isFinite(deltaMs) || deltaMs <= 0) return null
  const totalSeconds = Math.floor(deltaMs / 1000)
  const totalMinutes = Math.floor(totalSeconds / 60)
  const totalHours = Math.floor(totalMinutes / 60)
  const days = Math.floor(totalHours / 24)
  const hours = totalHours % 24
  const minutes = totalMinutes % 60

  if (days > 0) return `${days}d ${hours}h`
  if (totalHours > 0) return `${totalHours}h ${minutes}m`
  if (totalMinutes > 0) return `${totalMinutes}m`
  return "<1m"
}

function getLimitHitEtaText(
  used: number,
  limit: number,
  resetsAtMs: number,
  periodDurationMs: number,
  nowMs: number
): string | null {
  if (
    !Number.isFinite(used) ||
    !Number.isFinite(limit) ||
    !Number.isFinite(resetsAtMs) ||
    !Number.isFinite(periodDurationMs) ||
    !Number.isFinite(nowMs) ||
    limit <= 0 ||
    periodDurationMs <= 0
  ) {
    return null
  }
  if (used >= limit) return "at/over 100% now"

  const periodStartMs = resetsAtMs - periodDurationMs
  const elapsedMs = nowMs - periodStartMs
  if (elapsedMs <= 0 || nowMs >= resetsAtMs) return null

  const usageRatePerMs = used / elapsedMs
  if (!Number.isFinite(usageRatePerMs) || usageRatePerMs <= 0) return null

  const msUntilLimit = (limit - used) / usageRatePerMs
  if (!Number.isFinite(msUntilLimit) || msUntilLimit <= 0) return "at/over 100% now"

  const hitAtMs = nowMs + msUntilLimit
  if (hitAtMs >= resetsAtMs) return null

  const durationText = formatCompactDuration(hitAtMs - nowMs)
  return durationText ? `hits 100% in ${durationText}` : null
}

function PaceIndicator({ status, detailText }: { status: PaceStatus; detailText?: string | null }) {
  const colorClass =
    status === "ahead"
      ? "bg-green-500"
      : status === "on-track"
        ? "bg-yellow-500"
        : "bg-red-500"

  const statusText = getPaceStatusText(status)
  const tooltip = detailText ? `${statusText} • ${detailText}` : statusText

  return (
    <Tooltip>
      <TooltipTrigger
        render={(props) => (
          <span
            {...props}
            className={`inline-block w-2 h-2 rounded-full ${colorClass}`}
            aria-label={statusText}
          />
        )}
      />
      <TooltipContent side="top" className="text-xs">
        {tooltip}
      </TooltipContent>
    </Tooltip>
  )
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
  scopeFilter = "all",
  displayMode,
}: ProviderCardProps) {
  const cooldownRemainingMs = useMemo(() => {
    if (!lastManualRefreshAt) return 0
    const remaining = REFRESH_COOLDOWN_MS - (Date.now() - lastManualRefreshAt)
    return remaining > 0 ? remaining : 0
  }, [lastManualRefreshAt])

  // Filter lines based on scope - match by label since runtime lines can differ from manifest
  const overviewLabels = new Set(
    skeletonLines
      .filter(line => line.scope === "overview")
      .map(line => line.label)
  )
  const filteredSkeletonLines = scopeFilter === "all"
    ? skeletonLines
    : skeletonLines.filter(line => line.scope === "overview")
  const filteredLines = scopeFilter === "all"
    ? lines
    : lines.filter(line => overviewLabels.has(line.label))

  const hasResetCountdown = filteredLines.some(
    (line) => line.type === "progress" && Boolean(line.resetsAt)
  )

  const now = useNowTicker({
    enabled: cooldownRemainingMs > 0 || hasResetCountdown,
    intervalMs: cooldownRemainingMs > 0 ? 1000 : 30_000,
    stopAfterMs: cooldownRemainingMs > 0 && !hasResetCountdown ? cooldownRemainingMs : null,
  })

  const inCooldown = lastManualRefreshAt
    ? now - lastManualRefreshAt < REFRESH_COOLDOWN_MS
    : false

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
            <Badge
              variant="outline"
              className="truncate min-w-0 max-w-[40%]"
              title={plan}
            >
              {plan}
            </Badge>
          )}
        </div>
        {error && <PluginError message={error} />}

        {loading && !error && (
          <SkeletonLines lines={filteredSkeletonLines} />
        )}

        {!loading && !error && (
          <div className="space-y-4">
            {filteredLines.map((line, index) => (
              <MetricLineRenderer
                key={`${line.label}-${index}`}
                line={line}
                displayMode={displayMode}
                now={now}
              />
            ))}
          </div>
        )}
      </div>
      {showSeparator && <Separator />}
    </div>
  )
}

function MetricLineRenderer({
  line,
  displayMode,
  now,
}: {
  line: MetricLine
  displayMode: DisplayMode
  now: number
}) {
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
    const shownAmount =
      displayMode === "used"
        ? line.used
        : Math.max(0, line.limit - line.used)
    const percent = Math.round(clamp01(shownAmount / line.limit) * 10000) / 100
    const leftSuffix = displayMode === "left" ? " left" : ""

    const primaryText =
      line.format.kind === "percent"
        ? `${Math.round(shownAmount)}%${leftSuffix}`
        : line.format.kind === "dollars"
          ? `$${formatNumber(shownAmount)}${leftSuffix}`
          : `${formatCount(shownAmount)} ${line.format.suffix}${leftSuffix}`

    const secondaryText =
      line.resetsAt
        ? formatResetIn(now, line.resetsAt)
        : line.format.kind === "percent"
          ? `${line.limit}% cap`
          : line.format.kind === "dollars"
            ? `$${formatNumber(line.limit)} limit`
            : `${formatCount(line.limit)} ${line.format.suffix}`

    // Calculate pace status if we have reset time and period duration
    // If used === 0, always show "ahead" (no usage = definitionally ahead of pace)
    const paceResult =
      line.resetsAt && line.periodDurationMs
        ? calculatePaceStatus(
            line.used,
            line.limit,
            Date.parse(line.resetsAt),
            line.periodDurationMs,
            now
          )
        : null
    const paceStatus: PaceStatus | null =
      line.used === 0 && line.resetsAt && line.periodDurationMs ? "ahead" : (paceResult?.status ?? null)
    const projectedPercent =
      paceResult ? Math.round((paceResult.projectedUsage / line.limit) * 100) : null
    const paceDetailText =
      paceResult && projectedPercent !== null
        ? projectedPercent > 100 && line.resetsAt && line.periodDurationMs
          ? (
              getLimitHitEtaText(
                line.used,
                line.limit,
                Date.parse(line.resetsAt),
                line.periodDurationMs,
                now
              ) ?? `projected ${projectedPercent}% by reset`
            )
          : `projected ${projectedPercent}% by reset`
        : null

    return (
      <div>
        <div className="text-sm font-medium mb-1.5 flex items-center gap-1.5">
          {line.label}
          {paceStatus && <PaceIndicator status={paceStatus} detailText={paceDetailText} />}
        </div>
        <Progress
          value={percent}
          indicatorColor={line.color}
        />
        <div className="flex justify-between items-center mt-1.5">
          <span className="text-xs text-muted-foreground tabular-nums">
            {primaryText}
          </span>
          {secondaryText && (
            <span className="text-xs text-muted-foreground">
              {secondaryText}
            </span>
          )}
        </div>
      </div>
    )
  }

  return null
}
