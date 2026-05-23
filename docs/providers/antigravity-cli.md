# Antigravity CLI

Tracks Google Antigravity CLI (`agy`) Cloud Code quota.

## Setup

Sign in with the CLI first:

```bash
agy
```

OpenUsage uses the CLI keychain login. It does not start a browser OAuth flow.

## Data Sources

- Non-secret CLI context: `~/.gemini/antigravity-cli/`
- Auth: the Antigravity CLI OS keyring login. On macOS, current CLI builds store this under keychain service `gemini`, account `antigravity`.
- Quota APIs:
  - `POST https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - `POST https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  - `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

The provider does not read legacy Gemini OAuth files such as `~/.gemini/oauth_creds.json`.

## Quota Lines

- Gemini model IDs or labels containing `gemini` and `pro` -> `Gemini Pro`
- Gemini model IDs or labels containing `gemini` and `flash` -> `Gemini Flash`
- Other non-Gemini model pools -> `Claude`

When multiple buckets map to the same line, OpenUsage shows the lowest remaining fraction.

## Notes

Official Antigravity docs describe a shared agent harness and shared settings between the CLI and Antigravity 2.0. OpenUsage tracks Antigravity CLI separately because the CLI uses different state and auth paths.
