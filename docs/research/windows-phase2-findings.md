# Phase 2 Findings — Windows Provider Platform Adapters

Status: **COMPLETE on Windows machine** — spike build green, **282/282 tests passing** (3 skipped), 0 failures; e2e harness verified live for Claude/Codex/Cursor.
Date: 2026-07-10

Machine: `win32` developer box (PowerShell), Swift 6.3.3 `x86_64-unknown-windows-msvc`, VS 2022 Build Tools 17.14.

---

## Executive summary

Phase 2 delivered read-only credential research on a real Windows install, Windows platform adapters (`WindowsCredentialVaultAccessor`, `WinSQLiteAccessor` via `winsqlite3.dll`), a ported **Cursor** provider in `spikes/windows-core/`, and an **e2e-harness** executable. The spike remains green after adding **8 net-new tests** (282 total vs 274 in Phase 1).

**Key discovery:** `FileManager.urls(for: .applicationSupportDirectory)` on swift-corelibs-foundation Windows does **not** reliably resolve to `%APPDATA%`; Cursor's `state.vscdb` path must use the `APPDATA` environment variable explicitly (patch #26).

---

## Availability matrix (this machine)

| Provider | Class | Tool installed | Credential source verified | E2E harness |
|---|---|---|---|---|
| **Claude** | native | Yes — `claude` 2.1.201 (`~\.local\bin\claude.exe`) | `%USERPROFILE%\.claude\.credentials.json` (`claudeAiOauth`: accessToken, refreshToken, expiresAt, scopes, subscriptionType, rateLimitTier); keychain entry **not** present | credentialsFound=yes → refresh=success (7 lines, plan=Max 5x) |
| **Codex** | native | Yes — `codex-cli` 0.144.1 (npm) | `%USERPROFILE%\.codex\auth.json` (`auth_mode`, `tokens{id_token,access_token,refresh_token,account_id}`, `last_refresh`); `~\.config\codex\auth.json` absent; `CODEX_HOME` unset | credentialsFound=yes → refresh=success (8 lines, plan=Plus) |
| **Cursor** | native | Yes — Cursor 3.10.5 (`AppData\Local\Programs\cursor`) | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` — live read-only open finds `cursorAuth/accessToken` (len 411), `cursorAuth/refreshToken` (len 411), `cursorAuth/stripeMembershipType` (len 3); WAL/SHM sidecars present (`-wal` ~4.8 MB, `-shm` 32 KB) | credentialsFound=yes → refresh=success (7 lines, plan=Pro) |
| **Copilot** | native (partial) | Yes — `gh` 2.86.0 | `%APPDATA%\GitHub CLI\hosts.yml` (64 B, top key `github.com:`); Credential Manager `gh:github.com:Cagatay342` + `gh:github.com:`; `%LOCALAPPDATA%\github-copilot\{apps,hosts}.json` **absent** | Not in spike / not run |
| **Grok** | native | **No** — `grok` CLI not on PATH | `%USERPROFILE%\.grok\auth.json` and `logs\unified.jsonl` **absent** | credentialsFound=no |
| **Antigravity** | native (vault only) | Not verified as installed app | Credential Manager `LegacyGeneric:target=gemini:antigravity` (User=antigravity) — integration test reads non-empty blob | Not in spike / not run |
| **OpenRouter** | API-key-only | N/A | No env `OPENROUTER_API_KEY`; no `~\.config\openusage\openrouter.json` or `~\.config\openrouter\key.json` | credentialsFound=no |
| **Z.ai** | API-key-only | N/A | No env `ZAI_API_KEY` / `Z_AI_API_KEY`; no config files | credentialsFound=no |
| **Devin** | not-on-this-machine | Not installed | `%APPDATA%\Devin\...\state.vscdb` and `~\.local\share\devin\credentials.toml` **absent** | Not in spike |

---

## Installed tools (verified)

| Tool | Version | Path |
|---|---|---|
| Claude Code | 2.1.201 | `C:\Users\yildi\.local\bin\claude.exe` |
| Codex CLI | 0.144.1 | npm (`AppData\Roaming\npm\codex.ps1`) |
| GitHub CLI | 2.86.0 | `C:\Program Files\GitHub CLI\gh.exe` |
| Cursor | 3.10.5 (x64) | `AppData\Local\Programs\cursor\resources\app\bin\cursor.cmd` |
| Grok CLI | — | Not found on PATH |
| sqlite3 CLI | — | Not found on PATH |

---

## Verified credential paths (structure only — no secret values)

### Claude
- **File:** `C:\Users\yildi\.claude\.credentials.json` (4142 B)
- **Top keys:** `mcpOAuth`, `claudeAiOauth`
- **`claudeAiOauth` keys:** `accessToken`, `refreshToken`, `expiresAt`, `scopes`, `subscriptionType`, `rateLimitTier`
- **Token lengths:** accessToken=108, refreshToken=108; `subscriptionType=max`
- **`CLAUDE_CONFIG_DIR`:** unset (default `~\.claude` used)
- **Credential Manager:** `cmdkey /list` has **no** `Claude Code-credentials` entry on this machine; spike logs `read miss service=Claude Code-credentials` — file path is the live source

### Codex
- **File:** `C:\Users\yildi\.codex\auth.json` (4899 B) — **present**
- **Absent:** `~\.config\codex\auth.json`
- **Top keys:** `auth_mode`, `OPENAI_API_KEY`, `tokens`, `last_refresh`
- **`tokens` nested keys:** `id_token`, `access_token`, `refresh_token`, `account_id`
- **`CODEX_HOME`:** unset
- **Log dir:** `~\.codex\sessions` exists

### Cursor
- **File:** `%APPDATA%\Cursor\User\globalStorage\state.vscdb` (~1.07 GB)
- **Tables:** `ItemTable`, `cursorDiskKV`, `composerHeaders`
- **`ItemTable` cursorAuth keys (value lengths):**
  - `cursorAuth/accessToken` → 411
  - `cursorAuth/refreshToken` → 411
  - `cursorAuth/stripeMembershipType` → 3
  - Also present: `cachedEmail`, `cachedSignUpType`, `cachedScopedProfile`, `stripeSubscriptionStatus`
- **Sidecars:** `state.vscdb-wal` (~4.8 MB), `state.vscdb-shm` (32 KB)

### Copilot / gh
- **hosts.yml:** 64 B, contains `github.com:` entry
- **Credential Manager:** `gh:github.com:Cagatay342`, `gh:github.com:` (empty user)
- **github-copilot local JSON:** absent

### Antigravity
- **Credential Manager TargetName:** `gemini:antigravity` (go-keyring `service:account` convention)
- **User field:** `antigravity`
- Process/port discovery not implemented (Phase 2 stretch)

### Grok / Devin / API-key providers
- Grok auth + logs: absent
- Devin paths: absent
- OpenRouter/Z.ai config + env: absent

---

## Windows Credential Manager — TargetName conventions (observed)

| TargetName (CredReadW) | cmdkey display | User | Used by |
|---|---|---|---|
| `gemini:antigravity` | `LegacyGeneric:target=gemini:antigravity` | antigravity | Antigravity (go-keyring) |
| `gh:github.com:Cagatay342` | `LegacyGeneric:target=gh:github.com:Cagatay342` | Cagatay342 | GitHub CLI / Copilot |
| `gh:github.com:` | `LegacyGeneric:target=gh:github.com:` | (empty) | GitHub CLI host token |

**Spike mapping:** `WindowsCredentialVaultAccessor.readGenericPassword(service:account:)` tries `service:account`, then `service/account`, then service-only. Verified against live `gemini:antigravity` entry (integration test passes).

---

## SQLite / WAL behavior

| Scenario | Result |
|---|---|
| Live `state.vscdb` + `SQLITE_OPEN_READONLY` via `winsqlite3.dll` | **Works** while Cursor is running — tokens readable |
| Copy `state.vscdb` only (no WAL) to `%TEMP%` | `cursorAuth/*` keys **missing** (stale snapshot) |
| Copy `state.vscdb` + `-wal` + `-shm` to `%TEMP%` | Still **missing** tokens in our probe — WAL not checkpointed into main file |
| `WinSQLiteAccessor` policy | Open live path read-only first; on `SQLITE_BUSY`/`SQLITE_LOCKED`, copy bundle to temp and retry (fallback may be insufficient without checkpoint — live read is the primary path) |

**Practical outcome:** Opening the live DB read-only is sufficient on this machine; copy-fallback is a safety net for lock errors, not a full WAL-merge substitute.

---

## E2E harness results (2026-07-10, after APPDATA path fix)

```
OpenUsage Phase 2 e2e harness
platform=windows
provider=claude credentialsFound=yes
provider=claude refresh=success metricLines=7 plan=Max 5x
provider=codex credentialsFound=yes
provider=codex refresh=success metricLines=8 plan=Plus
provider=cursor credentialsFound=yes
provider=cursor refresh=success metricLines=7 plan=Pro
provider=grok credentialsFound=no
provider=openrouter credentialsFound=no
provider=zai credentialsFound=no
```

Run: `spikes\windows-core\.build\x86_64-unknown-windows-msvc\debug\e2e-harness.exe` (after `swift build` in vcvars64 + `SDKROOT`).

Claude refresh took ~122 s (live usage API + pricing network fetches).

---

## Spike build/test (final)

| Metric | Phase 1 | Phase 2 |
|---|---|---|
| Library Swift sources | 71 | **~79** (+ Cursor provider, adapters, harness API) |
| Test files | 18 | **19** |
| Providers in spike | 5 | **6** (+ Cursor) |
| Tests executed | 274 (3 skipped) | **282 (3 skipped)** |
| Failures | 0 | **0** |
| Products | library | library + **e2e-harness** executable |

Invocation (unchanged):

```powershell
$env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT","User")
cd spikes\windows-core
cmd /s /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat`" && swift build && swift test"
```

---

## Patches (Phase 2 — spike only, continuing Phase 0/1 table)

| # | File | What changed | Why |
|---|---|---|---|
| 26 | `Support/WellKnownPaths.swift` | `applicationSupport` reads `%APPDATA%` on Windows; added `cursorStateDBPath` | corelibs `applicationSupportDirectory` ≠ Cursor's real path; broke `hasLocalCredentials()` until fixed |
| 27 | `Sources/Win32Shim/` (new) | C shim: `ou_sqlite.c` (dynamic `winsqlite3.dll`), `ou_wincred.c` (`CredReadW`) | Linked SQLite + Credential Manager without macOS `sqlite3`/`security` CLIs |
| 28 | `Services/WinSQLiteAccessor.swift`, `Services/WindowsCredentialVaultAccessor.swift` | `SQLiteAccessing` + `KeychainAccessing` Windows implementations | Phase 2 platform adapters; read-only writes (Phase 2 policy) |
| 29 | `Providers/Cursor/*` (6 files) | Ported from main tree; `CursorAuthStore` defaults to Win adapters + Windows DB path | Cursor provider on Windows |
| 30 | `Services/Phase2E2EHarness.swift`, `Sources/e2e-harness/` | Headless verification executable | Per-provider credential/refresh reporting without secrets |
| 31 | `Providers/ErrorCategory.swift` | `CursorAuthError` / `CursorUsageError` conformances | Telemetry categories for Cursor |
| 32 | `Services/SystemClients.swift` | `NoOpSQLiteAccessor` stub for non-Windows compiles | CursorAuthStore default factory |
| 33 | `Tests/OpenUsageCoreTests/CursorProviderTests.swift` | Auth store, mapper, provider, WinSQLite, WinCred tests | Regression + fixture coverage |
| 34 | `Package.swift` | `Win32Shim` target, `e2e-harness` executable product | Build/link advapi32 + winsqlite3 |

---

## Write-back policy (Phase 2 — not implemented)

Per plan gate: third-party stores are **read-only** in this phase.

- `WinSQLiteAccessor.execute` → throws `SQLiteError.readOnly`
- `WindowsCredentialVaultAccessor.write*` → throws `KeychainError.writeFailed("read-only…")`
- `CursorProvider.refresh()` may attempt token rotation; persist to SQLite fails loudly in logs but session continues (matches macOS fail-loud pattern)

Owner sign-off still required before enabling write-back per provider.

---

## What remains for full Phase 2

| Item | Notes |
|---|---|
| **Copilot provider** | Not ported to spike; `hosts.yml` + gh vault entries exist — needs provider copy + Windows auth-store paths |
| **Devin provider** | Not on this machine; SQLite path TBD |
| **Antigravity provider** | Vault entry verified; needs `LanguageServerDiscovery` Windows port (Toolhelp32/TCP table) or cloud-fallback decision |
| **Grok on this machine** | CLI not installed — verify on a Grok-equipped Windows host |
| **OpenRouter / Z.ai live refresh** | API-key-only; need keys in env or `~\.config\openusage\*.json` for e2e |
| **Claude Credential Manager** | Some builds use `Claude Code-credentials` — not present here; branch when found |
| **WAL copy-fallback hardening** | Consider `sqlite3_backup` or checkpoint-via-uri if live open fails under AV/lock |
| **Write-back policy** | Per-provider owner decision + ACL (`0600` equivalent) for OpenUsage-written files |
| **go-keyring blob encoding** | Verify UTF-8 vs UTF-16 for non-gh entries when Copilot/Antigravity land |
| **Apply adapters to main tree** | Phase 1 target split still macOS-gated |

---

## Files created/modified (Phase 2 session)

### Created
- `docs/research/windows-phase2-findings.md` (this file)
- `spikes/windows-core/Sources/Win32Shim/` — `ou_sqlite.c`, `ou_wincred.c`, `include/ou_shim.h`, `module.modulemap`
- `spikes/windows-core/Sources/OpenUsageCore/Services/WinSQLiteAccessor.swift`
- `spikes/windows-core/Sources/OpenUsageCore/Services/WindowsCredentialVaultAccessor.swift`
- `spikes/windows-core/Sources/OpenUsageCore/Services/Phase2E2EHarness.swift`
- `spikes/windows-core/Sources/OpenUsageCore/Providers/Cursor/` — 6 Swift files
- `spikes/windows-core/Sources/e2e-harness/main.swift`
- `spikes/windows-core/Tests/OpenUsageCoreTests/CursorProviderTests.swift`

### Modified
- `spikes/windows-core/Package.swift`
- `spikes/windows-core/Sources/OpenUsageCore/Support/WellKnownPaths.swift`
- `spikes/windows-core/Sources/OpenUsageCore/Services/SystemClients.swift`
- `spikes/windows-core/Sources/OpenUsageCore/Providers/ErrorCategory.swift`

### Not modified (per scope guardrails)
- `Sources/OpenUsage/`, `Tests/OpenUsageTests/`, root `Package.swift`, `docs/research/windows-port-plan.md`

---

## Blockers

| Blocker | Severity | Mitigation |
|---|---|---|
| `%APPDATA%` vs `FileManager.applicationSupport` mismatch | **Fixed** (patch #26) | Always use explicit env vars for Windows well-known dirs |
| WAL copy-fallback incomplete | Low on this machine | Live read-only open works; document limit |
| Copilot/Devin/Antigravity providers not in spike | Medium | Port provider modules + Windows discovery in follow-up |
| No Grok/OpenRouter/Z.ai keys on this host | Low | Classified correctly; e2e skips |
| Write-back policy unsigned | Medium | Owner decision before mutating third-party stores |
| Claude refresh latency (~2 min) | Low | Network + log scan; acceptable for harness |
