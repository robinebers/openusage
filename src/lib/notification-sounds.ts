type SoundEntry = {
  file: string;
  message: string;
  providerId: string;
  lineLabel: string;
};

function key(providerId: string, lineLabel: string): string {
  return `${providerId}:${lineLabel.trim().toLowerCase()}`;
}

function entry(providerId: string, lineLabel: string, file: string, message: string): [string, SoundEntry] {
  return [key(providerId, lineLabel), { providerId, lineLabel, file, message }];
}

const SOUND_ENTRIES = new Map<string, SoundEntry>([
  entry("amp", "Free", "amp-free.mp3", "Amp free usage refreshed."),
  entry("antigravity", "Gemini Pro", "antigravity-gemini-pro.mp3", "Antigravity Gemini Pro refreshed."),
  entry("antigravity", "Gemini Flash", "antigravity-gemini-flash.mp3", "Antigravity Gemini Flash refreshed."),
  entry("antigravity", "Claude", "antigravity-claude.mp3", "Antigravity Claude access refreshed."),
  entry("claude", "Session", "claude-session.mp3", "Claude session refreshed."),
  entry("claude", "Weekly", "claude-weekly.mp3", "Claude weekly quota refreshed."),
  entry("claude", "Sonnet", "claude-sonnet.mp3", "Claude Sonnet usage refreshed."),
  entry("claude", "Claude Design", "claude-design.mp3", "Claude Design quota refreshed."),
  entry("claude", "Extra usage spent", "claude-extra-usage.mp3", "Claude extra usage is available again."),
  entry("codex", "Session", "codex-session.mp3", "Codex session refreshed."),
  entry("codex", "Weekly", "codex-weekly.mp3", "Codex weekly quota refreshed."),
  entry("codex", "Spark", "codex-spark.mp3", "Codex Spark refreshed."),
  entry("codex", "Spark Weekly", "codex-spark-weekly.mp3", "Codex Spark weekly quota refreshed."),
  entry("codex", "Reviews", "codex-reviews.mp3", "Codex review quota refreshed."),
  entry("codex", "Credits", "codex-credits.mp3", "Codex credits refreshed."),
  entry("copilot", "Premium", "copilot-premium.mp3", "Copilot premium usage refreshed."),
  entry("copilot", "Chat", "copilot-chat.mp3", "Copilot chat refreshed."),
  entry("copilot", "Completions", "copilot-completions.mp3", "Copilot completions refreshed."),
  entry("cursor", "Credits", "cursor-credits.mp3", "Cursor credits refreshed."),
  entry("cursor", "Total usage", "cursor-total-usage.mp3", "Cursor total usage refreshed."),
  entry("cursor", "Requests", "cursor-requests.mp3", "Cursor requests refreshed."),
  entry("cursor", "Auto usage", "cursor-auto-usage.mp3", "Cursor auto usage refreshed."),
  entry("cursor", "API usage", "cursor-api-usage.mp3", "Cursor API usage refreshed."),
  entry("cursor", "On-demand", "cursor-on-demand.mp3", "Cursor on-demand usage refreshed."),
  entry("factory", "Standard", "factory-standard.mp3", "Factory standard usage refreshed."),
  entry("factory", "Premium", "factory-premium.mp3", "Factory premium usage refreshed."),
  entry("gemini", "Pro", "gemini-pro.mp3", "Gemini Pro refreshed."),
  entry("gemini", "Flash", "gemini-flash.mp3", "Gemini Flash refreshed."),
  entry("jetbrains-ai-assistant", "Quota", "jetbrains-quota.mp3", "JetBrains AI Assistant quota refreshed."),
  entry("kimi", "Session", "kimi-session.mp3", "Kimi session refreshed."),
  entry("kimi", "Weekly", "kimi-weekly.mp3", "Kimi weekly quota refreshed."),
  entry("kiro", "Credits", "kiro-credits.mp3", "Kiro credits refreshed."),
  entry("kiro", "Bonus Credits", "kiro-bonus-credits.mp3", "Kiro bonus credits refreshed."),
  entry("minimax", "Session", "minimax-session.mp3", "MiniMax session refreshed."),
  entry("mock", "Provider", "mock-provider.mp3", "Mock provider refreshed."),
  entry("mock", "Session", "mock-session.mp3", "Mock session refreshed."),
  entry("mock", "Credits", "mock-credits.mp3", "Mock credits refreshed."),
  entry("mock", "Quota", "mock-quota.mp3", "Mock quota refreshed."),
  entry("mock", "Chaos Meter", "mock-chaos-meter.mp3", "Mock chaos meter refreshed."),
  entry("mock", "Test Limit", "mock-test-limit.mp3", "Mock test limit refreshed."),
  entry("opencode-go", "5h Rate Limit", "opencode-go-5h-limit.mp3", "OpenCode Go five-hour limit refreshed."),
  entry("opencode-go", "Subscription", "opencode-go-subscription.mp3", "OpenCode Go subscription usage refreshed."),
  entry("opencode-go", "Session", "opencode-go-session.mp3", "OpenCode Go session refreshed."),
  entry("opencode-go", "Quota", "opencode-go-quota.mp3", "OpenCode Go quota refreshed."),
  entry("opencode-go", "Weekly", "opencode-go-quota.mp3", "OpenCode Go weekly quota refreshed."),
  entry("opencode-go", "Monthly", "opencode-go-subscription.mp3", "OpenCode Go monthly usage refreshed."),
  entry("perplexity", "API Credits", "perplexity-api-credits.mp3", "Perplexity API credits refreshed."),
  entry("synthetic", "5h Rate Limit", "synthetic-5h-limit.mp3", "Synthetic five-hour limit refreshed."),
  entry("synthetic", "Mana Bar", "synthetic-mana-bar.mp3", "Synthetic mana bar recharged."),
  entry("synthetic", "Subscription", "synthetic-subscription.mp3", "Synthetic subscription usage refreshed."),
  entry("synthetic", "Free Tool Calls", "synthetic-free-tool-calls.mp3", "Synthetic free tool calls refreshed."),
  entry("synthetic", "Search", "synthetic-search.mp3", "Synthetic search quota refreshed."),
  entry("windsurf", "Daily Quota", "windsurf-daily-quota.mp3", "Windsurf daily quota refreshed."),
  entry("windsurf", "Weekly Quota", "windsurf-weekly-quota.mp3", "Windsurf weekly quota refreshed."),
  entry("zai", "Session", "zai-session.mp3", "Z.ai session refreshed."),
  entry("zai", "Weekly", "zai-weekly.mp3", "Z.ai weekly quota refreshed."),
  entry("zai", "Web Searches", "zai-web-searches.mp3", "Z.ai web searches refreshed."),
]);

const PLUGIN_LINE_LABELS = new Map<string, string[]>();
for (const sound of SOUND_ENTRIES.values()) {
  const list = PLUGIN_LINE_LABELS.get(sound.providerId) ?? [];
  if (!list.includes(sound.lineLabel)) list.push(sound.lineLabel);
  PLUGIN_LINE_LABELS.set(sound.providerId, list);
}

export function getNotificationSoundEntry(
  providerId: string,
  lineLabel: string
): SoundEntry | null {
  return SOUND_ENTRIES.get(key(providerId, lineLabel)) ?? null;
}

export function getAlertableLineLabels(providerId: string): string[] {
  return PLUGIN_LINE_LABELS.get(providerId) ?? [];
}

export function buildAlertKey(providerId: string, lineLabel: string): string {
  return key(providerId, lineLabel);
}
