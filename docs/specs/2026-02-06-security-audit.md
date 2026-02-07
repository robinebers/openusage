# Spec: security audit

## Goal
- Produce an in-repo, in-depth security audit report for the current codebase.

## Scope
- Dependency risk review (package.json + lockfile) and automated audit tooling.
- Static review of security-relevant configurations (frontend + Tauri).
- Spot checks for common insecure patterns (e.g., eval, innerHTML, insecure URL handling).

## Non-goals
- No code changes unless a critical fix is obvious and safe.
- No external pentesting or runtime fuzzing.

## Deliverables
- `docs/security-audit-2026-02-06.md` with findings, evidence, and recommendations.
