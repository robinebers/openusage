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

export const WINDOWS_V1_PROVIDER_IDS = ["claude", "codex", "cursor"] as const

export const WINDOWS_PROVIDER_SUPPORT: Record<string, WindowsProviderSupport> = {
  amp: {
    status: "deferred",
    detectionStrategy: "Unix local secrets file under `~/.local/share/amp/secrets.json`.",
    dependencies: ["Amp CLI session", "Unix-style local data layout"],
    note: "Unix-only local data layout needs a Windows discovery pass before this provider is worth enabling.",
  },
  antigravity: {
    status: "blocked",
    detectionStrategy: "macOS VS Code-style sqlite state under `~/Library/Application Support/Antigravity/...`.",
    dependencies: ["Antigravity desktop app", "sqlite3"],
    note: "Current implementation is tied to the macOS app-storage layout and cannot run on Windows unchanged.",
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
    status: "planned",
    detectionStrategy: "GitHub CLI or UsageTray-managed credential storage.",
    dependencies: ["GitHub CLI auth or Windows credential bridge"],
    note: "Windows credential-manager support needs to land before Copilot can be promoted to the first support wave.",
  },
  cursor: {
    status: "v1",
    detectionStrategy: "Reads `%APPDATA%/Cursor/User/globalStorage/state.vscdb` and probes Cursor APIs with the stored session.",
    dependencies: ["Cursor desktop app signed in locally", "sqlite3"],
    note: "No usable Cursor session was detected yet. Open Cursor, sign in once, and keep the local state database intact.",
  },
  factory: {
    status: "planned",
    detectionStrategy: "Local auth files under `~/.factory` with optional keychain fallback.",
    dependencies: ["Factory CLI auth"],
    note: "Factory looks close to portable, but it is outside the first Windows milestone.",
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
    status: "blocked",
    detectionStrategy: "macOS state database under `~/Library/Application Support/Windsurf/...`.",
    dependencies: ["Windsurf desktop app", "sqlite3"],
    note: "Windsurf is still hard-coded to macOS application data paths and is not yet supportable on Windows.",
  },
  zai: {
    status: "planned",
    detectionStrategy: "API-key based via `ZAI_API_KEY` or `GLM_API_KEY`.",
    dependencies: ["Windows environment variable setup"],
    note: "Z.ai is likely portable, but the v1 support set is intentionally limited to Claude, Codex, and Cursor.",
  },
}

function looksLikeDetectionGap(error: string | null): boolean {
  if (!error) return false
  return [
    /^Not logged in\b/i,
    /^No active Cursor subscription\./i,
    /^Usage not available for API key\./i,
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
