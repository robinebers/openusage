// FILE: tray-alert.ts
// Purpose: Centralizes weekly-warning rules for the menubar/tray metric selection.
// Layer: UI utility
// Exports: tray alert severity helpers + primary metric selection for tray rendering.

import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"
import type { WeeklyWarningThresholdPercent } from "@/lib/settings"
import { clamp01 } from "@/lib/utils"

export type TrayAlertSeverity = "none" | "warning" | "critical"

type ProgressLine = Extract<
  PluginOutput["lines"][number],
  { type: "progress"; label: string; used: number; limit: number }
>

export type TrayPrimaryMetricSelection = {
  line: ProgressLine | null
  warningSeverity: TrayAlertSeverity
  weeklyRemainingPercent: number | null
}

const WEEKLY_LABEL_RE = /\bweek/i

function isProgressLine(line: PluginOutput["lines"][number]): line is ProgressLine {
  return line.type === "progress"
}

function findMatchingProgressLine(
  lines: PluginOutput["lines"],
  labels: string[]
): ProgressLine | null {
  for (const label of labels) {
    const match = lines.find(
      (line): line is ProgressLine => isProgressLine(line) && line.label === label
    )
    if (match) return match
  }
  return null
}

function getWeeklyOverviewLabels(meta: PluginMeta): string[] {
  return meta.lines
    .filter((line) => line.type === "progress" && line.scope === "overview" && WEEKLY_LABEL_RE.test(line.label))
    .map((line) => line.label)
}

function findWeeklyProgressLine(meta: PluginMeta, data: PluginOutput): ProgressLine | null {
  const metaWeekly = findMatchingProgressLine(data.lines, getWeeklyOverviewLabels(meta))
  if (metaWeekly) return metaWeekly

  return (
    data.lines.find(
      (line): line is ProgressLine => isProgressLine(line) && WEEKLY_LABEL_RE.test(line.label)
    ) ?? null
  )
}

function getRemainingPercent(line: ProgressLine | null): number | null {
  if (!line || !Number.isFinite(line.limit) || line.limit <= 0 || !Number.isFinite(line.used)) {
    return null
  }
  return Math.round(clamp01((line.limit - line.used) / line.limit) * 100)
}

function getCriticalThresholdPercent(
  thresholdPercent: WeeklyWarningThresholdPercent
): number {
  return Math.max(5, Math.round(thresholdPercent / 2))
}

// Promotes the weekly metric once remaining weekly budget crosses the configured threshold.
export function selectTrayPrimaryMetric(args: {
  meta: PluginMeta
  data: PluginOutput | null
  weeklyWarningThresholdPercent: WeeklyWarningThresholdPercent
}): TrayPrimaryMetricSelection {
  const { meta, data, weeklyWarningThresholdPercent } = args
  if (!data) {
    return {
      line: null,
      warningSeverity: "none",
      weeklyRemainingPercent: null,
    }
  }

  const primaryLine = findMatchingProgressLine(data.lines, meta.primaryCandidates ?? [])
  const weeklyLine = findWeeklyProgressLine(meta, data)
  const weeklyRemainingPercent = getRemainingPercent(weeklyLine)

  let warningSeverity: TrayAlertSeverity = "none"
  if (weeklyRemainingPercent !== null) {
    const criticalThresholdPercent = getCriticalThresholdPercent(weeklyWarningThresholdPercent)
    if (weeklyRemainingPercent <= criticalThresholdPercent) {
      warningSeverity = "critical"
    } else if (weeklyRemainingPercent <= weeklyWarningThresholdPercent) {
      warningSeverity = "warning"
    }
  }

  const line =
    primaryLine &&
    weeklyLine &&
    primaryLine.label !== weeklyLine.label &&
    warningSeverity !== "none"
      ? weeklyLine
      : primaryLine

  return {
    line,
    warningSeverity,
    weeklyRemainingPercent,
  }
}

