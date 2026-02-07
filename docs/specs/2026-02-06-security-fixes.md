# Spec: security fixes

## Goal
- Remove high/medium security risks identified in the audit by tightening CSP and plugin permissions.

## Scope
- Enable CSP in Tauri config.
- Add plugin permission manifest + enforce host API allowlists.
- Pin Git dependencies to immutable commits.
- Add JS lockfile to enable npm audit.

## Non-goals
- No UI changes beyond security config.
- No dependency upgrades unless required to unblock audits.

## Deliverables
- Updated Tauri config, plugin runtime, and plugin manifests.
- `package-lock.json` to enable npm audit.
