# Ollama

> Tracks Ollama Cloud session and weekly usage from the account settings page.

## Overview

- **Provider ID:** `ollama`
- **Source of truth:** `https://ollama.com/settings`
- **Auth:** Ollama web session cookie (`__Secure-session`)
- **Status:** alpha, because Ollama does not document a cloud quota API yet

Ollama documents per-request generation metrics such as `prompt_eval_count`, `eval_count`, and durations, but those are not the same as account quota usage. The Cloud Usage dashboard shows the quota users care about:

- `Session` percent, usually a 5-hour window
- `Weekly` percent, usually a 7-day window
- plan label (`Free`, `Pro`, `Max`, or `Team`)

## Authentication

The plugin tries credentials in this order:

1. `OLLAMA_SESSION_COOKIE`: raw `__Secure-session` value.
2. `OLLAMA_COOKIE`: full Cookie header containing `__Secure-session=...`.
3. macOS Keychain item `OpenUsage Ollama Session` for the current user.
4. macOS Keychain item `OpenUsage Ollama Cookie` for the current user.
5. Firefox or LibreWolf `cookies.sqlite` when signed in to `ollama.com`.

Manual Keychain setup:

```sh
security add-generic-password -U -a "$(id -un)" -s "OpenUsage Ollama Session" -w "PASTE_SESSION_COOKIE"
```

If Ollama later ships `GET /api/account/usage`, the plugin can use it with `OLLAMA_API_KEY` when no settings-page cookie is available. Today that endpoint is expected to be absent, so `/settings` is the primary source.

## Data Mapping

Settings HTML is parsed for:

- the first `N% used` value as `Session`
- the second `N% used` value as `Weekly`
- `data-time="..."` reset timestamps when present
- relative reset text (`Resets in 55 minutes`) as a fallback

## Output

- **Plan**: account plan label when present.
- **Session**: percent progress line, primary tray candidate.
- **Weekly**: percent progress line.
- **Source**: whether data came from the settings page or a future API endpoint.

## Failure Behavior

| Condition | Message |
|---|---|
| No cookie found | `Ollama auth missing. Set OLLAMA_SESSION_COOKIE or sign in with Firefox.` |
| Cookie expired or redirected | `Ollama session expired. Update your session cookie.` |
| Settings page shape changed | `Could not parse Ollama Cloud usage from settings.` |
| Network failure | `Could not reach ollama.com. Check your connection.` |

This plugin never sends prompt text or model requests. It only reads the account settings page.
