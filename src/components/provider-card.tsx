import { Fragment, useMemo } from "react"
import { ExternalLink, Hourglass, RefreshCw } from "lucide-react"
import { openUrl } from "@tauri-apps/plugin-opener"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { Separator } from "@/components/ui/separator"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { SkeletonLines } from "@/components/skeleton-lines"
import { PluginError } from "@/components/plugin-error"
import { useNowTicker } from "@/hooks/use-now-ticker"
import { REFRESH_COOLDOWN_MS, type DisplayMode, type ResetTimerDisplayMode } from "@/lib/settings"
import type { ManifestLine, MetricLine, PluginLink } from "@/lib/plugin-types"
import { groupLinesByType } from "@/lib/group-lines-by-type"
import { clamp01, formatCountNumber, formatFixedPrecisionNumber } from "@/lib/utils"
import { calculateDeficit, calculatePaceStatus, type PaceStatus } from "@/lib/pace-status"
import { buildPaceDetailText, formatCompactDuration, formatDeficitText, formatRunsOutText, getPaceStatusText } from "@/lib/pace-tooltip"

interface ProviderCardProps {
  name: string
  plan?: string
  links?: PluginLink[]
  showSeparator?: boolean
  loading?: boolean
  error?: string | null
  lines?: MetricLine[]
  skeletonLines?: ManifestLine[]
  lastManualRefreshAt?: number | null
  onRetry?: () => void
  scopeFilter?: "overview" | "all"
  displayMode: DisplayMode
  resetTimerDisplayMode?: ResetTimerDisplayMode
  onResetTimerDisplayModeToggle?: () => void
}

const PACE_VISUALS: Record<PaceStatus, { dotClass: string }> = {
  ahead: { dotClass: "bg-green-500" },
  "on-track": { dotClass: "bg-yellow-500" },
  behind: { dotClass: "bg-red-500" },
}


const RESET_SOON_THRESHOLD_MS = 5 * 60 * 1000

function formatResetIn(nowMs: number, resetsAtIso: string): string | null {
  const resetsAtMs = Date.parse(resetsAtIso)
  if (!Number.isFinite(resetsAtMs)) return null
  const deltaMs = resetsAtMs - nowMs
  if (deltaMs < RESET_SOON_THRESHOLD_MS) return "Resets soon"
  const durationText = formatCompactDuration(deltaMs)!
  return `Resets in ${durationText}`
}

const RESET_TIME_FORMATTER = new Intl.DateTimeFormat(undefined, {
  hour: "numeric",
  minute: "2-digit",
})

const RESET_MONTH_FORMATTER = new Intl.DateTimeFormat(undefined, {
  month: "short",
})

function getLocalDayIndex(timestampMs: number): number {
  const date = new Date(timestampMs)
  return Math.floor(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86_400_000)
}

function getEnglishOrdinalSuffix(day: number): string {
  const mod100 = day % 100
  if (mod100 >= 11 && mod100 <= 13) return "th"
  const mod10 = day % 10
  if (mod10 === 1) return "st"
  if (mod10 === 2) return "nd"
  if (mod10 === 3) return "rd"
  return "th"
}

function formatMonthDayWithOrdinal(timestampMs: number): string {
  const date = new Date(timestampMs)
  const monthText = RESET_MONTH_FORMATTER.format(date)
  const day = date.getDate()
  return `${monthText} ${day}${getEnglishOrdinalSuffix(day)}`
}

function formatResetAt(nowMs: number, resetsAtIso: string): string | null {
  const resetsAtMs = Date.parse(resetsAtIso)
  if (!Number.isFinite(resetsAtMs)) return null
  if (resetsAtMs - nowMs <= 0) return "Resets soon"
  const dayDiff = getLocalDayIndex(resetsAtMs) - getLocalDayIndex(nowMs)
  const timeText = RESET_TIME_FORMATTER.format(resetsAtMs)
  if (dayDiff <= 0) return `Resets today at ${timeText}`
  if (dayDiff === 1) return `Resets tomorrow at ${timeText}`
  const dateText = formatMonthDayWithOrdinal(resetsAtMs)
  return `Resets ${dateText} at ${timeText}`
}

/** Colored dot indicator showing pace status */
function PaceIndicator({
  status,
  detailText,
  isLimitReached,
}: {
  status: PaceStatus
  detailText?: string | null
  isLimitReached?: boolean
}) {
  const colorClass = PACE_VISUALS[status].dotClass

  const statusText = getPaceStatusText(status)

  return (
    <Tooltip>
      <TooltipTrigger
        render={(props) => (
          <span
            {...props}
            className={`inline-block w-2 h-2 rounded-full ${colorClass}`}
            aria-label={isLimitReached ? "Limit reached" : statusText}
          />
        )}
      />
      <TooltipContent side="top" className="text-xs text-center">
        {isLimitReached ? (
          "Limit reached"
        ) : (
          <>
            <div>{statusText}</div>
            {detailText && <div className="text-[10px] opacity-60">{detailText}</div>}
          </>
        )}
      </TooltipContent>
    </Tooltip>
  )
}

export function ProviderCard({
  name,
  plan,
  links = [],
  showSeparator = true,
  loading = false,
  error = null,
  lines = [],
  skeletonLines = [],
  lastManualRefreshAt,
  onRetry,
  scopeFilter = "all",
  displayMode,
  resetTimerDisplayMode = "relative",
  onResetTimerDisplayModeToggle,
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

  const visibleLinks = useMemo(
    () =>
      links
        .map((link) => ({
          label: link.label.trim(),
          url: link.url.trim(),
        }))
        .filter(
          (link) =>
            link.label.length > 0 &&
            link.url.length > 0 &&
            (link.url.startsWith("https://") || link.url.startsWith("http://"))
        ),
    [links]
  )

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
        {visibleLinks.length > 0 && (
          <div className="mb-2 -mt-0.5 flex flex-wrap gap-1.5">
            {visibleLinks.map((link) => (
              <Button
                key={`${link.label}-${link.url}`}
                variant="outline"
                size="xs"
                className="h-6 max-w-full text-[11px]"
                onClick={() => {
                  openUrl(link.url).catch(console.error)
                }}
              >
                <span className="truncate">{link.label}</span>
                <ExternalLink className="size-3 opacity-70" />
              </Button>
            ))}
          </div>
        )}
        {error && <PluginError message={error} />}

        {loading && !error && (
          <SkeletonLines lines={filteredSkeletonLines} />
        )}

        {!loading && !error && (
          <div className="space-y-4">
            {groupLinesByType(filteredLines).map((group, gi) =>
              group.kind === "text" ? (
                <div key={gi} className="space-y-1">
                  {group.lines.map((line, li) => (
                    <MetricLineRenderer
                      key={`${line.label}-${gi}-${li}`}
                      line={line}
                      displayMode={displayMode}
                      resetTimerDisplayMode={resetTimerDisplayMode}
                      onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
                      now={now}
                    />
                  ))}
                </div>
              ) : (
                <Fragment key={gi}>
                  {group.lines.map((line, li) => (
                    <MetricLineRenderer
                      key={`${line.label}-${gi}-${li}`}
                      line={line}
                      displayMode={displayMode}
                      resetTimerDisplayMode={resetTimerDisplayMode}
                      onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
                      now={now}
                    />
                  ))}
                </Fragment>
              )
            )}
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
  resetTimerDisplayMode,
  onResetTimerDisplayModeToggle,
  now,
}: {
  line: MetricLine
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  onResetTimerDisplayModeToggle?: () => void
  now: number
}) {
  if (line.type === "text") {
    return (
      <div>
        <div className="flex justify-between items-center h-[18px]">
          <span className="text-xs text-muted-foreground flex-shrink-0">{line.label}</span>
          <span
            className="text-xs text-muted-foreground truncate min-w-0 max-w-[60%] text-right"
            style={line.color ? { color: line.color } : undefined}
            title={line.value}
          >
            {line.value}
          </span>
        </div>
        {line.subtitle && (
          <div className="text-[10px] text-muted-foreground text-right -mt-0.5">{line.subtitle}</div>
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
    const resetsAtMs = line.resetsAt ? Date.parse(line.resetsAt) : Number.NaN
    const periodDurationMs = line.periodDurationMs
    const hasPaceContext = Number.isFinite(resetsAtMs) && Number.isFinite(periodDurationMs)
    const hasTimeMarkerContext = hasPaceContext && periodDurationMs! > 0
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
          ? `$${formatFixedPrecisionNumber(shownAmount)}${leftSuffix}`
          : `${formatCountNumber(shownAmount)} ${line.format.suffix}${leftSuffix}`

    const resetLabel = line.resetsAt
      ? resetTimerDisplayMode === "absolute"
        ? formatResetAt(now, line.resetsAt)
        : formatResetIn(now, line.resetsAt)
      : null

    const secondaryText =
      resetLabel ??
      (line.format.kind === "percent"
        ? `${line.limit}% cap`
        : line.format.kind === "dollars"
          ? `$${formatFixedPrecisionNumber(line.limit)} limit`
          : `${formatCountNumber(line.limit)} ${line.format.suffix}`)

    // Calculate pace status if we have reset time and period duration
    const paceResult = hasPaceContext
      ? calculatePaceStatus(line.used, line.limit, resetsAtMs, periodDurationMs!, now)
      : null
    const paceStatus = paceResult?.status ?? null
    const paceMarkerValue = hasTimeMarkerContext && paceStatus && paceStatus !== "on-track"
      ? (() => {
          const periodStartMs = resetsAtMs - periodDurationMs!
          const elapsedFraction = clamp01((now - periodStartMs) / periodDurationMs!)
          const elapsedPercent = elapsedFraction * 100
          return displayMode === "used" ? elapsedPercent : 100 - elapsedPercent
        })()
      : undefined
    const isLimitReached = line.used >= line.limit
    const paceDetailText =
      hasPaceContext && !isLimitReached
        ? buildPaceDetailText({
            paceResult,
            used: line.used,
            limit: line.limit,
            periodDurationMs: periodDurationMs!,
            resetsAtMs,
            nowMs: now,
            displayMode,
          })
        : null

    const deficit = hasPaceContext && !isLimitReached
      ? calculateDeficit(line.used, line.limit, resetsAtMs, periodDurationMs!, now)
      : null
    const deficitText = deficit !== null
      ? formatDeficitText(deficit, line.format, displayMode)
      : null
    const runsOutText = hasPaceContext && !isLimitReached
      ? formatRunsOutText({
          paceResult,
          used: line.used,
          limit: line.limit,
          periodDurationMs: periodDurationMs!,
          resetsAtMs,
          nowMs: now,
        })
      : null

    return (
      <div>
        <div className="text-sm font-medium mb-1.5 flex items-center gap-1.5">
          {line.label}
          {paceStatus && (
            <PaceIndicator status={paceStatus} detailText={paceDetailText} isLimitReached={isLimitReached} />
          )}
        </div>
        <Progress
          value={percent}
          indicatorColor={line.color}
          markerValue={paceMarkerValue}
        />
        <div className="flex justify-between items-center mt-1.5">
          <span className="text-xs text-muted-foreground tabular-nums">
            {primaryText}
          </span>
          {secondaryText && (
            resetLabel && onResetTimerDisplayModeToggle ? (
              <button
                type="button"
                onClick={onResetTimerDisplayModeToggle}
                className="text-xs text-muted-foreground tabular-nums hover:text-foreground transition-colors"
              >
                {secondaryText}
              </button>
            ) : (
              <span className="text-xs text-muted-foreground">
                {secondaryText}
              </span>
            )
          )}
        </div>
        {(deficitText || runsOutText) && (
          <div className="flex justify-between items-center mt-0.5">
            {deficitText && (
              <span className="text-xs text-muted-foreground tabular-nums">
                {deficitText}
              </span>
            )}
            {runsOutText && (
              <span className="text-xs text-muted-foreground tabular-nums ml-auto">
                {runsOutText}
              </span>
            )}
          </div>
        )}
      </div>
    )
  }

  return null
}
