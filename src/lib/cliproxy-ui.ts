export type CliProxyConfigView = {
  configured: boolean
  baseUrl: string | null
}

export type CliProxyAuthFile = {
  id: string
  name: string
  provider: string
  email?: string | null
  authIndex?: string | null
  disabled: boolean
  unavailable: boolean
  runtimeOnly?: boolean
}

export type AccountOption = {
  value: string
  label: string
}

export const OVERLAY_ENABLED_PLUGIN_IDS = new Set(["codex", "claude", "kimi", "antigravity", "gemini"])
export const HIDDEN_PLUGIN_IDS = new Set(["cliproxyapi"])
export const LOCAL_ACCOUNT_VALUE = "__local__"
export const LOCAL_ACCOUNT_LABEL = "Local account"

export function toCliProxyConfigView(value: unknown): CliProxyConfigView {
  if (!value || typeof value !== "object") {
    return { configured: false, baseUrl: null }
  }
  const obj = value as Record<string, unknown>
  return {
    configured: obj.configured === true,
    baseUrl: typeof obj.baseUrl === "string" ? obj.baseUrl : null,
  }
}

export function mapAuthProviderToPluginId(provider: string) {
  const normalized = provider.trim().toLowerCase()
  if (normalized === "anthropic") return "claude"
  if (normalized === "google" || normalized === "google-ai" || normalized === "gemini-cli") {
    return "gemini"
  }
  return normalized
}

export function buildAccountOptionsByPlugin(authFiles: CliProxyAuthFile[]) {
  const byPlugin: Record<string, AccountOption[]> = {}
  const seen: Record<string, Set<string>> = {}

  for (const pluginId of OVERLAY_ENABLED_PLUGIN_IDS) {
    byPlugin[pluginId] = [{ value: LOCAL_ACCOUNT_VALUE, label: LOCAL_ACCOUNT_LABEL }]
    seen[pluginId] = new Set([LOCAL_ACCOUNT_VALUE])
  }

  for (const file of authFiles) {
    if (file.disabled || file.unavailable) continue
    if (!file.name || !file.name.toLowerCase().endsWith(".json")) continue

    const pluginId = mapAuthProviderToPluginId(file.provider || "")
    if (!OVERLAY_ENABLED_PLUGIN_IDS.has(pluginId)) continue

    const rawSelection = (file.authIndex || file.id || file.name || "").trim()
    if (!rawSelection) continue

    const label = file.email?.trim()
      ? `${file.email.trim()} (${file.name})`
      : file.name

    if (!seen[pluginId]) seen[pluginId] = new Set<string>()
    if (seen[pluginId].has(rawSelection)) continue
    seen[pluginId].add(rawSelection)

    if (!byPlugin[pluginId]) byPlugin[pluginId] = []
    byPlugin[pluginId].push({ value: rawSelection, label })
  }

  return byPlugin
}

export function filterCliProxySelectionsForProbe(accountSelections: Record<string, string>) {
  return Object.fromEntries(
    Object.entries(accountSelections).filter(
      ([pluginId, value]) =>
        OVERLAY_ENABLED_PLUGIN_IDS.has(pluginId) &&
        typeof value === "string" &&
        value.trim() !== "" &&
        value !== LOCAL_ACCOUNT_VALUE
    )
  )
}
