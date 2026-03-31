import type { PluginDisplayState } from "@/lib/plugin-types"

export type WindowsProviderStatus = "v1" | "planned" | "deferred" | "blocked"
export type WindowsProviderAvailability = "ready" | "not-detected" | "planned" | "blocked" | null

export type WindowsProviderAvailabilityNote = {
  kind: "not-detected" | "planned" | "blocked"
  title: string
  message: string
  suppressError: boolean
}

type WindowsProviderSupport = {
  status: WindowsProviderStatus
  detectionStrategy: string
  dependencies: string[]
  note: string
}

export const WINDOWS_V1_PROVIDER_IDS = [
  "antigravity",
  "claude",
  "codex",
  "copilot",
  "cursor",
  "factory",
  "windsurf",
  "zai",
] as const

export const WINDOWS_PROVIDER_SUPPORT: Record<string, WindowsProviderSupport> = {
  amp: {
    status: "deferred",
    detectionStrategy: "Unix local secrets file under `~/.local/share/amp/secrets.json`.",
    dependencies: ["Amp CLI session", "Unix-style local data layout"],
    note: "Unix-only local data layout needs a Windows discovery pass before this provider is worth enabling.",
  },
  antigravity: {
    status: "v1",
    detectionStrategy: "Reads `%APPDATA%/Antigravity/User/globalStorage/state.vscdb` and probes the local Antigravity language server when the desktop app is running.",
    dependencies: ["Antigravity desktop app signed in locally", "sqlite3"],
    note: "No usable Antigravity session was detected yet. Open Antigravity once, sign in, and keep its local state database available.",
  },
  claude: {
    status: "v1",
    detectionStrategy: "Primary file check at `~/.claude/.credentials.json`; Windows keychain fallback is out of v1 scope.",
    dependencies: ["Claude Code signed in locally", "optional `ccusage` runner for token history"],
    note: "No local Claude login was detected yet. UsageTray checks `~/.claude/.credentials.json`. Sign in with `claude` first.",
  },
  codex: {
    status: "v1",
    detectionStrategy: "Checks `%CODEX_HOME%/auth.json`, `%APPDATA%/codex/auth.json`, `%LOCALAPPDATA%/codex/auth.json`, then `~/.codex/auth.json`.",
    dependencies: ["Codex CLI signed in locally", "optional `ccusage` runner for token history"],
    note: "No local Codex auth was detected yet. Run `codex login` so an `auth.json` is present.",
  },
  copilot: {
    status: "v1",
    detectionStrategy: "Reads UsageTray-managed credentials first, then Windows Credential Manager entries created by `gh auth login`.",
    dependencies: ["GitHub CLI signed in locally or a cached UsageTray token"],
    note: "No local Copilot auth was detected yet. Run `gh auth login` and keep the GitHub CLI session available for UsageTray.",
  },
  cursor: {
    status: "v1",
    detectionStrategy: "Reads `%APPDATA%/Cursor/User/globalStorage/state.vscdb` and probes Cursor APIs with the stored session.",
    dependencies: ["Cursor desktop app signed in locally", "sqlite3"],
    note: "No usable Cursor session was detected yet. Open Cursor, sign in once, and keep the local state database intact.",
  },
  factory: {
    status: "v1",
    detectionStrategy: "Reads `~/.factory/auth.v2.file` or legacy auth files, with Windows keychain fallback.",
    dependencies: ["Factory CLI auth"],
    note: "No local Factory auth was detected yet. Run `droid` so `~/.factory` contains a valid auth session.",
  },
  gemini: {
    status: "deferred",
    detectionStrategy: "Looks for `~/.gemini` credentials and Unix-oriented global npm/bun install paths.",
    dependencies: ["Gemini CLI auth", "provider-specific OAuth helper discovery"],
    note: "Gemini depends on Unix-heavy install-path probing and needs a Windows-specific credential discovery pass.",
  },
  "jetbrains-ai-assistant": {
    status: "planned",
    detectionStrategy: "Already has Windows AppData lookup support under `~/AppData/Roaming/JetBrains`.",
    dependencies: ["JetBrains IDE local data", "sqlite3 if needed by probe"],
    note: "This provider is a strong Windows candidate, but it stays out of v1 while the first-wave providers are stabilized.",
  },
  kimi: {
    status: "planned",
    detectionStrategy: "Credential file under `~/.kimi/credentials/kimi-code.json`.",
    dependencies: ["Kimi CLI auth"],
    note: "Kimi appears portable, but it is intentionally deferred until the first wave is complete.",
  },
  minimax: {
    status: "planned",
    detectionStrategy: "API-key based via `MINIMAX_*` environment variables.",
    dependencies: ["Windows environment variable setup"],
    note: "Minimax is likely low effort on Windows, but it is not part of the first milestone.",
  },
  "opencode-go": {
    status: "deferred",
    detectionStrategy: "Unix local-share auth and sqlite database under `~/.local/share/opencode`.",
    dependencies: ["OpenCode Go local files", "sqlite3"],
    note: "OpenCode Go currently assumes a Unix local-share layout and needs a Windows storage strategy first.",
  },
  perplexity: {
    status: "blocked",
    detectionStrategy: "macOS cache database under `~/Library/.../Cache.db`.",
    dependencies: ["Perplexity desktop app", "sqlite3"],
    note: "Perplexity is blocked behind macOS-specific cache discovery and is not yet supportable on Windows.",
  },
  windsurf: {
    status: "v1",
    detectionStrategy: "Reads `%APPDATA%/Windsurf/User/globalStorage/state.vscdb` and `%APPDATA%/Windsurf - Next/User/globalStorage/state.vscdb`.",
    dependencies: ["Windsurf desktop app", "sqlite3"],
    note: "No usable Windsurf session was detected yet. Open Windsurf, sign in once, and keep the local state database intact.",
  },
  zai: {
    status: "v1",
    detectionStrategy: "API-key based via `ZAI_API_KEY` or `GLM_API_KEY`.",
    dependencies: ["Windows environment variable setup"],
    note: "No Z.ai API key was detected yet. Set `ZAI_API_KEY` (or `GLM_API_KEY`) in your Windows environment and restart UsageTray.",
  },
}

function looksLikeDetectionGap(error: string | null): boolean {
  if (!error) return false
  return [
    /^Not logged in\b/i,
    /^No active Cursor subscription\./i,
    /^Usage not available for API key\./i,
    /^No ZAI_API_KEY found\./i,
    /^Start .+ and try again\./i,
  ].some((pattern) => pattern.test(error))
}

export function classifyWindowsProviderAvailability(plugin: PluginDisplayState): WindowsProviderAvailability {
  const support = WINDOWS_PROVIDER_SUPPORT[plugin.meta.id]
  if (!support || plugin.loading) return null
  if (plugin.data && !plugin.error) return "ready"

  if (support.status === "blocked") return "blocked"
  if (support.status === "planned" || support.status === "deferred") return "planned"
  if (support.status === "v1" && looksLikeDetectionGap(plugin.error)) return "not-detected"

  return null
}

export function getWindowsProviderAvailabilityNote(
  plugin: PluginDisplayState
): WindowsProviderAvailabilityNote | null {
  const availability = classifyWindowsProviderAvailability(plugin)
  const support = WINDOWS_PROVIDER_SUPPORT[plugin.meta.id]
  if (!availability || availability === "ready" || !support) return null

  if (availability === "not-detected") {
    return {
      kind: "not-detected",
      title: "Supported on Windows",
      message: support.note,
      suppressError: true,
    }
  }

  if (availability === "planned") {
    return {
      kind: "planned",
      title: "Planned for Windows",
      message: support.note,
      suppressError: true,
    }
  }

  return {
    kind: "blocked",
    title: "Not yet supported on Windows",
    message: support.note,
    suppressError: true,
  }
}
