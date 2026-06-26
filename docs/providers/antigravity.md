# Antigravity

Tracks per-model quota for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity exposes a separate quota for each model, which OpenUsage groups into three meters:

| Metric | Meaning |
|---|---|
| Gemini Pro | Remaining quota for the Gemini Pro models (worst-case across variants) |
| Gemini Flash | Remaining quota for the Gemini Flash models |
| Claude | Remaining quota for every non-Gemini model (Claude, GPT-OSS, …), which share one pool |
| Plan | Your subscription tier, e.g. `Pro` or `Ultra` (optional widget) |

Each meter shows how much of the rolling 5-hour window you've used, and when it resets. Quotas are reported as a fraction (full = 0% used), so there are no token or dollar spend tiles. The model lineup is read live from Antigravity, so new models appear on their own.

## Where credentials come from

OpenUsage never asks for a token — it reads what Antigravity already has:

- **Antigravity running** — OpenUsage talks to the app's local language server (the richest source, and where the plan name comes from).
- **App closed** — it falls back to the OAuth token Antigravity / `agy` store in your macOS Keychain and queries Google's Cloud Code API. An expired token is refreshed automatically (OpenUsage never writes back to Antigravity's own keychain item).

If neither is available you'll see *Start Antigravity or run `agy` and try again.*

## Troubleshooting

- **"Start Antigravity or run `agy`…"** — sign in to the Antigravity app (or run `agy`) so a usable token exists, then refresh.
- **A meter shows "No data"** — that model pool wasn't in the latest response (e.g. no Gemini Flash model provisioned). The other meters still update.
- **Quotas look full after heavy use** — they reset every ~5 hours; the reset time is shown on each meter.

## Under the hood

Best source first: the local language server (`GetUserStatus`, falling back to `GetCommandModelConfigs`) discovered by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code (`fetchAvailableModels` for quota, `loadCodeAssist` for the plan) using the Keychain token, refreshed via Google OAuth when needed. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field. Internal and duplicate models are filtered out before the pools are built.

> Reverse-engineered from the app and language-server binary; endpoints and storage may change without notice.
