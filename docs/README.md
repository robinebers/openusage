# OpenUsage Documentation

What the app does and how it behaves. These pages describe **behavior, not visuals**, and they are updated together with any change to that behavior — if the app and a page here disagree, that's a bug.

## The app

- [Dashboard](dashboard.md) — the popover: rows, toggles, reordering, keyboard shortcuts
- [Menu bar](menu-bar.md) — pinning metrics into the menu bar
- [Settings](settings.md) — every option, what it changes
- [Refreshing & caching](refreshing.md) — when data updates and what happens when a fetch fails
- [iCloud Sync](icloud-sync.md) — how spend history is combined across Macs
- [Model pricing](pricing.md) — how spend tiles price tokens, and where the rates come from
- [Updates](updates.md) — automatic updates, manual checks, and the beta channel
- [Privacy & usage data](privacy.md) — what anonymous data is shared, and how to turn it off

## Integrations

- [Command-line interface](cli.md) — one-shot cached and forced usage reads for agents and scripts
- [Local HTTP API](local-http-api.md) — read your usage from other apps on `127.0.0.1:6736`
- [Proxy](proxy.md) — route provider requests through SOCKS5 or HTTP(S)

## Providers

What each provider tracks, where its credentials come from, and what to do when it shows an error.

- [Antigravity](providers/antigravity.md)
- [Claude](providers/claude.md)
- [Codex](providers/codex.md)
- [Copilot](providers/copilot.md)
- [Cursor](providers/cursor.md)
- [Devin](providers/devin.md)
- [Grok](providers/grok.md)
- [OpenCode](providers/opencode.md)
- [OpenRouter](providers/openrouter.md)
- [Z.ai](providers/zai.md)

## For developers

How the app is built and how to extend it.

- [Architecture](architecture.md) — composition root, stores, the provider pipeline, the AppKit bridge
- [Adding a provider](adding-a-provider.md) — the metric contract and the register/test/document steps
- [Debugging & capturing logs](debugging.md) — running a local build and streaming logs
- [Logging](logging.md) — the file log, log levels, subsystem tags, and what is never logged
