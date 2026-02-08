# Gemini

Tracks Gemini CLI usage via OAuth credentials and Gemini quota APIs.  
No browser cookies required.

## Data sources

- `~/.gemini/settings.json` for auth type.
- `~/.gemini/oauth_creds.json` for OAuth tokens.
- OAuth client ID/secret extracted from Gemini CLI `oauth2.js`.

## Supported auth modes

- `oauth-personal` (supported)
- unknown / missing auth type (treated as OAuth, supported)

## Unsupported auth modes

- `api-key`
- `vertex-ai`

These return an explicit error in OpenUsage.

## API endpoints

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
- `GET https://cloudresourcemanager.googleapis.com/v1/projects` (project fallback)
- `POST https://oauth2.googleapis.com/token` (refresh)

## Output mapping

- **Plan** from `loadCodeAssist` tier:
  - `standard-tier` -> `Paid`
  - `free-tier` + `hd` claim -> `Workspace`
  - `free-tier` -> `Free`
  - `legacy-tier` -> `Legacy`
- **Pro** line: Gemini Pro bucket with lowest remaining fraction.
- **Flash** line: Gemini Flash bucket with lowest remaining fraction.
- **Account** line: email from `id_token` claims.
