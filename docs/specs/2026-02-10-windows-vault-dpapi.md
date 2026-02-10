# Windows Vault (DPAPI)

## Goal
- Protect OpenUsage-managed tokens on Windows using DPAPI instead of plaintext files.

## Scope
- Add `host.vault` API (read/write/delete) backed by DPAPI user-scope encryption.
- Store vault entries under `appDataDir/vault/<encoded-key>`.
- Update Copilot plugin to use vault on Windows.
- Document vault API and Copilot auth order.

## Non-Goals
- Replace provider-owned credential files (Claude/Codex).
- Integrate with Windows Credential Manager for third-party secrets.
- Add UI for manual token entry.

## Approach
- Use `windows-dpapi` crate (`encrypt_data`/`decrypt_data`, `Scope::User`).
- Base64-encode encrypted bytes for storage on disk.
- Encode vault key names using URL-safe base64 to avoid filesystem issues.

## Testing
- `cargo test` (src-tauri)
- `bun test plugins/copilot/plugin.test.js`

## Risks
- DPAPI ties data to user profile; tokens are not portable across machines.
- gh CLI token access on Windows depends on whether `hosts.yml` contains `oauth_token`.

## Open Questions
- None.
