# Copilot

Tracks your GitHub Copilot quota using a GitHub token that Copilot tooling already left on your machine. No login flow, no browser cookies.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Share of your monthly AI-credit allotment used (the headline meter) |
| Extra Usage | Premium interactions used beyond your included credits, once extra spend is enabled |
| Chat | Chat-message quota used |
| Completions | Code-completion quota used |

Credits and Extra Usage show above the fold; Chat and Completions sit under the "Shown on expand" caret. Each meter shows percent used and, when the response includes one, a countdown to the next reset. The plan name (Pro, Business, Free, …) shows next to the provider.

Since June 2026 GitHub Copilot bills all plans by **AI credits**, so what each account shows differs by plan:

- **Paid plans** meter the credit pool — so you see Credits (and Extra Usage if you've turned on additional spend). Chat and completions are unlimited on paid plans, so those rows read "No data".
- **Free plans** have no credits, so Credits reads "No data"; instead you see your fixed Chat and Completions counts under the caret.
- **Copilot Business / token-based billing** returns no per-seat quota, so there's nothing to meter. The provider still shows the plan; the meters read "No data" rather than fabricating numbers.

A dollar credit figure (e.g. "$12 of $15 used") isn't shown: GitHub only exposes that through its logged-in web billing page, which would require reading browser cookies — OpenUsage does not do that. Editors like VS Code show the same credit *percentage* from this endpoint, not a dollar amount.

## Where credentials come from

Checked in this order (prompt-free files first, Keychain last):

1. Copilot editor token: `~/.config/github-copilot/apps.json` (older `hosts.json`) — written by the VS Code / JetBrains / Neovim Copilot plugins.
2. GitHub CLI config: `~/.config/gh/hosts.yml` (`oauth_token`), when `gh` stores its token in a file.
3. GitHub CLI Keychain item (service `gh:github.com`), when `gh` stores its token in the system keyring.

### Setup

If usage doesn't appear, authenticate with the GitHub CLI:

```bash
brew install gh   # if needed
gh auth login     # choose GitHub.com and follow the prompts
```

Using Copilot in a supported editor is enough on its own — the editor writes the token to `apps.json`.

## Troubleshooting

- **"Sign in to GitHub Copilot…"** — no token was found. Sign in to Copilot in your editor, or run `gh auth login`.
- **"GitHub token invalid or expired"** — the token was rejected (401/403). Re-authenticate with `gh auth login`.
- **Meters show "No data" but the plan is shown** — expected on Copilot Business / token-based-billing seats; GitHub doesn't expose per-seat quota for them.

## Under the hood

`GET https://api.github.com/copilot_internal/user` with the standard Copilot client headers (API version `2025-04-01`). The response reports each bucket as percent *remaining*; the meters show percent *used*.
