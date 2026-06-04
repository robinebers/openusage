export type ProgressFormat =
  | { kind: "percent" }
  | { kind: "dollars" }
  | { kind: "count"; suffix: string }

export type BarChartPoint = {
  label: string
  value: number
  valueLabel?: string
}

export type MetricLine =
  | { type: "text"; label: string; value: string; color?: string; subtitle?: string }
  | {
      type: "progress"
      label: string
      used: number
      limit: number
      format: ProgressFormat
      resetsAt?: string
      periodDurationMs?: number
      color?: string
    }
  | { type: "badge"; label: string; text: string; color?: string; subtitle?: string }
  | { type: "barChart"; label: string; points: BarChartPoint[]; note?: string; color?: string }

export type ManifestLine = {
  type: "text" | "progress" | "badge" | "barChart"
  label: string
  scope: "overview" | "detail"
}

export type PluginLink = {
  label: string
  url: string
}

export type PluginOutput = {
  providerId: string
  displayName: string
  plan?: string
  lines: MetricLine[]
  iconUrl: string
  links?: PluginLink[]
}

export type PluginMeta = {
  id: string
  name: string
  iconUrl: string
  brandColor?: string
  lines: ManifestLine[]
  links?: PluginLink[]
  /** Ordered list of primary metric candidates. Frontend picks first available. */
  primaryCandidates: string[]
}

export type PluginDisplayState = {
  meta: PluginMeta
  data: PluginOutput | null
  loading: boolean
  error: string | null
  lastManualRefreshAt: number | null
  lastUpdatedAt: number | null
}
