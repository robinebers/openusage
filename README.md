# UsageTray

UsageTray is a Windows tray app for tracking AI coding subscription usage in one place.

This repository is an unofficial Windows-focused fork of [OpenUsage](https://github.com/robinebers/openusage). It is not affiliated with, endorsed by, or an official part of the original OpenUsage project.

## Status

- Windows-only fork
- Tested locally with both Codex and Claude Code
- Manual updates through GitHub releases

## Download

[**Download the latest release**](https://github.com/Rana-Faraz/usage-tray-windows/releases/latest) (Windows x64)

## What It Does

UsageTray lives in your Windows tray and shows usage data for supported AI coding tools in a single popup panel.

- One-glance usage visibility across supported providers
- Automatic refresh on a configurable schedule
- Global shortcut support
- Single-popup tray UI
- Local plugin-based provider architecture
- [Local HTTP API](docs/local-http-api.md) on `127.0.0.1:6736`

## Supported Providers

- [**Amp**](docs/providers/amp.md) / free tier, bonus, credits
- [**Antigravity**](docs/providers/antigravity.md) / all models
- [**Claude**](docs/providers/claude.md) / session, weekly, extra usage, local token usage (ccusage)
- [**Codex**](docs/providers/codex.md) / session, weekly, reviews, credits
- [**Copilot**](docs/providers/copilot.md) / premium, chat, completions
- [**Cursor**](docs/providers/cursor.md) / credits, total usage, auto usage, API usage, on-demand, CLI auth
- [**Factory / Droid**](docs/providers/factory.md) / standard, premium tokens
- [**Gemini**](docs/providers/gemini.md) / pro, flash, workspace/free/paid tier
- [**JetBrains AI Assistant**](docs/providers/jetbrains-ai-assistant.md) / quota, remaining
- [**Kimi Code**](docs/providers/kimi.md) / session, weekly
- [**MiniMax**](docs/providers/minimax.md) / coding plan session
- [**OpenCode Go**](docs/providers/opencode-go.md) / 5h, weekly, monthly spend limits
- [**Windsurf**](docs/providers/windsurf.md) / prompt credits, flex credits
- [**Z.ai**](docs/providers/zai.md) / session, weekly, web searches

## Trademark Note

OpenUsage is a trademark of Robin Ebers. This project uses the OpenUsage name only to identify the upstream project it was forked from.

## Contributing

Contributions are welcome for Windows provider support, shell behavior, and packaging improvements.

## License

[MIT](LICENSE)
