# GitHub Copilot

Tracks GitHub Copilot usage quotas for both paid and free tier users.

## Authentication

The plugin looks for a GitHub token in this order:

1. **OpenUsage Keychain** (`OpenUsage-copilot`) — Token previously cached by the plugin
2. **GitHub CLI Keychain** (`gh:github.com`) — Token from `gh auth login`
3. **State File** (`auth.json`) — Fallback file-based storage

### Setup

Install and authenticate with the GitHub CLI:

```bash
# Install gh CLI (macOS)
brew install gh

# Authenticate
gh auth login
```

Choose "GitHub.com" and follow the prompts. The plugin will automatically read the token from the gh CLI keychain.

Once authenticated via gh CLI, the plugin caches the token in the OpenUsage keychain for faster access on subsequent probes.

## API

**Endpoint:** `https://api.github.com/copilot_internal/user`

**Headers:**
```
Authorization: token <token>
Accept: application/json
Editor-Version: vscode/1.96.2
Editor-Plugin-Version: copilot-chat/0.26.7
User-Agent: GitHubCopilotChat/0.26.7
X-Github-Api-Version: 2025-04-01
```

### Response (Paid Tier)

```json
{
  "copilot_plan": "pro",
  "quota_reset_date": "2025-02-15T00:00:00Z",
  "quota_snapshots": {
    "premium_interactions": {
      "percent_remaining": 80,
      "entitlement": 300,
      "remaining": 240,
      "quota_id": "premium"
    },
    "chat": {
      "percent_remaining": 95,
      "entitlement": 1000,
      "remaining": 950,
      "quota_id": "chat"
    }
  }
}
```

### Response (Free Tier)

```json
{
  "copilot_plan": "individual",
  "access_type_sku": "free_limited_copilot",
  "limited_user_quotas": {
    "chat": 410,
    "completions": 4000
  },
  "monthly_quotas": {
    "chat": 500,
    "completions": 4000
  },
  "limited_user_reset_date": "2025-02-11"
}
```

## Displayed Lines

| Line           | Tier | Description                                          |
|----------------|------|------------------------------------------------------|
| Premium        | Paid | Premium interactions remaining (percent)             |
| Requests Used  | Paid | Premium requests used vs. entitlement (e.g. 60 / 300)|
| Chat           | Both | Chat messages remaining                              |
| Completions    | Free | Code completions remaining                           |

All progress lines include:
- `resetsAt` — ISO timestamp of next quota reset
- `periodDurationMs` — 30-day period (2592000000ms)

## Errors

| Condition       | Message                                           |
|-----------------|---------------------------------------------------|
| No token found  | "Not logged in. Run `gh auth login` first."       |
| 401/403         | "Token invalid. Run `gh auth login` to re-auth."  |
| HTTP error      | "Usage request failed (HTTP {status})..."         |
| Network error   | "Usage request failed. Check your connection."    |
| Invalid JSON    | "Usage response invalid. Try again later."        |
