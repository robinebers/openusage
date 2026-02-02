export type MetricLine =
  | { type: "text"; label: string; value: string; color?: string; subtitle?: string }
  | { type: "progress"; label: string; value: number; max: number; unit?: "percent" | "dollars"; color?: string; subtitle?: string }
  | { type: "badge"; label: string; text: string; color?: string; subtitle?: string }

export type ManifestLine = {
  type: "text" | "progress" | "badge"
  label: string
}

export type PluginOutput = {
  providerId: string
  displayName: string
  plan?: string
  lines: MetricLine[]
  iconUrl: string
}

export type PluginMeta = {
  id: string
  name: string
  iconUrl: string
  brandColor?: string
  lines: ManifestLine[]
}
