# Antigravity CLI

This provider reads Google Antigravity CLI (`agy`) usage from the Cloud Code quota APIs used by the CLI. It is separate from the Antigravity IDE and Gemini providers because `agy` stores state and auth differently.

Authenticate with `agy` before enabling this provider:

```sh
agy
```

OpenUsage reads non-secret context only from `~/.gemini/antigravity-cli/`. It does not read legacy Gemini OAuth files such as `~/.gemini/oauth_creds.json`.

Authentication comes from the Antigravity CLI OS keyring login. On macOS, current CLI builds store it under keychain service `gemini` and account `antigravity`. The provider accepts raw tokens, JSON OAuth-style payloads, and `go-keyring-base64:` wrapped values when the keychain returns them.

Official Antigravity docs describe a shared agent harness and shared settings between the CLI and Antigravity 2.0. OpenUsage tracks Antigravity CLI separately so the auth path and implementation remain clear.
