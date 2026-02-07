# Security audit (2026-02-06)

## Executive summary
- Overall risk: **High** due to disabled CSP and un-sandboxed plugin execution with privileged host APIs.
- No evidence of obvious credential leakage in logs; redaction exists in host API logging.
- Dependency audit tooling incomplete because npm audit requires a package-lock; process gap remains.

## Scope
- Static review of Tauri configuration, plugin execution model, and privileged host APIs.
- Dependency risk review from `package.json` and Rust crate configuration.
- Targeted pattern scan for dangerous APIs in application source.

## Methods (local)
- Manual config and code review (`src-tauri/*`, `src/*`, `plugins/*`).
- Targeted pattern scans for CSP and unsafe API usage.
- Attempted `npm audit` (blocked by missing package-lock).

## Findings

### 1) CSP disabled in Tauri configuration (High)
**Evidence**: Tauri security config sets `csp: null`, which disables CSP enforcement for the webview.【F:src-tauri/tauri.conf.json†L21-L28】
**Impact**: Any XSS in the web UI could execute with full webview privileges, potentially bridging to Tauri APIs depending on frontend exposure.
**Recommendation**:
- Enable a restrictive CSP for production (script-src 'self' plus required hashes/nonces; disallow `unsafe-inline`/`unsafe-eval`).
- If inline styles/scripts are needed, move to external files or use hashes.

### 2) Plugin scripts execute with powerful host APIs and no permission gating (High)
**Evidence**: Plugin runtime evaluates arbitrary plugin JS (`ctx.eval(entry_script)`), which runs inside the application and accesses host APIs injected into `__openusage_ctx`.【F:src-tauri/src/plugin_engine/runtime.rs†L54-L102】
**Evidence**: Host APIs expose filesystem read/write, HTTP requests, keychain access, and sqlite CLI execution to plugins without allowlists or scoped permissions.【F:src-tauri/src/plugin_engine/host_api.rs†L171-L218】【F:src-tauri/src/plugin_engine/host_api.rs†L220-L356】【F:src-tauri/src/plugin_engine/host_api.rs†L665-L869】
**Evidence**: Plugins are loaded from local directories (dev dir or app data `plugins`) with only basic manifest validation and no signature verification or permission checks.【F:src-tauri/src/plugin_engine/mod.rs†L7-L41】【F:src-tauri/src/plugin_engine/manifest.rs†L56-L104】
**Impact**: A malicious or tampered plugin can read/write arbitrary files (including credential material), exfiltrate data over HTTP, access keychain entries, and run sqlite commands.
**Recommendation**:
- Introduce a permission model (capabilities in manifest + user consent) for host APIs (fs, http, keychain, sqlite).
- Require plugin signing or integrity verification before loading.
- Restrict plugin install paths and disable dev plugin loading in production builds.

### 3) Plugin HTTP client has no destination allowlist (Medium)
**Evidence**: Plugin HTTP requests are built from untrusted plugin-provided URLs with no host allowlist or scheme validation beyond what reqwest accepts.【F:src-tauri/src/plugin_engine/host_api.rs†L220-L333】
**Impact**: Plugins can exfiltrate sensitive data or communicate with arbitrary remote endpoints.
**Recommendation**:
- Add allowlist or per-plugin network permissions, with optional user prompts.
- Log and rate-limit outbound requests; consider blocking non-HTTPS URLs.

### 4) Git-based dependency without pinned commit (Medium)
**Evidence**: `tauri-nspanel` is sourced from a Git branch (`branch = "v2.1"`) rather than a commit hash, making builds dependent on mutable history.【F:src-tauri/Cargo.toml†L29-L34】
**Impact**: Supply-chain risk; builds can change without code changes in this repo.
**Recommendation**:
- Pin Git dependencies to a specific commit SHA and document upgrade procedure.

### 5) JS dependency audit tooling gap (Low)
**Evidence**: `npm audit` cannot run because there is no `package-lock.json` in the repo; only `bun.lock` exists, so npm reports `ENOLOCK`. (command attempted locally)
**Impact**: Automated JS vulnerability reporting is currently blocked by tooling mismatch.
**Recommendation**:
- Standardize on one lockfile and audit tool; if using Bun, add a Bun-compatible audit process or generate an npm lockfile for audits.

## Positive controls observed
- Plugin entry path is canonicalized to prevent path traversal outside the plugin directory.【F:src-tauri/src/plugin_engine/manifest.rs†L73-L104】
- HTTP logging redacts sensitive values before writing to logs (JWTs and API key patterns).【F:src-tauri/src/plugin_engine/host_api.rs†L1-L109】【F:src-tauri/src/plugin_engine/host_api.rs†L304-L336】
- HTTP client disables redirects to reduce SSRF-style pivoting through redirects.【F:src-tauri/src/plugin_engine/host_api.rs†L254-L261】

## Recommended next steps (prioritized)
1. **Enable CSP** with a tight default policy for production builds; document any required exceptions.
2. **Add plugin permissions + signing**; require explicit user consent for keychain/fs/http/sqlite access.
3. **Pin Git dependencies** to commit SHAs and audit update cadence.
4. **Define a dependency audit path** for Bun (or add a package-lock just for audits).

