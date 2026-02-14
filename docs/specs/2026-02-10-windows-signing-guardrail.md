# Windows Signing Guardrail

## Goal
- Fail releases when Windows signing secrets are missing.

## Scope
- Add a validation step in `.github/workflows/publish.yml` for Windows signing secrets.

## Non-Goals
- Change signing identity, certificate format, or release process.

## Approach
- On `windows-latest`, error out if `WINDOWS_CERTIFICATE` or `WINDOWS_CERTIFICATE_PASSWORD` is unset.
- Always run the import step after validation.

## Testing
- No automated tests; validate via workflow run.

## Risks
- Manual releases without secrets will now fail (intended).

## Open Questions
- None.
