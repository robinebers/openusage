# Copilot

Tracks your GitHub Copilot quota using a GitHub token that Copilot tooling already left on your machine. No login flow, no browser cookies.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Share of your monthly AI-credit allotment used (the headline meter) |
| Extra Usage | Premium interactions used beyond your included credits, once extra spend is enabled |
| Org Credits | AI credits your whole organization used this month (org-managed Business/Enterprise seats) |
| Org Spend | Dollars your organization was billed for AI credits beyond the included pool |
| Chat | Chat-message quota used |
| Completions | Code-completion quota used |

Credits and Extra Usage are Always Visible by default; Org Credits, Org Spend, Chat, and Completions start in On Demand behind the card's caret. Each meter shows percent used and, when the response includes one, a countdown to the next reset. The plan name (Pro, Business, Free, …) shows next to the provider.

Since June 2026 GitHub Copilot bills all plans by **AI credits**, so what each account shows differs by plan:

- **Paid plans** meter the credit pool — so you see Credits (and Extra Usage if you've turned on additional spend). Chat and completions are unlimited on paid plans, so those rows read "No data".
- **Free plans** have no credits, so Credits reads "No data"; instead you see your fixed Chat and Completions counts under the caret.
- **Org-managed seats (Copilot Business / Enterprise assigned by an organization)** return no per-seat quota, so the personal meters have nothing to show. OpenUsage then looks the usage up in the organization's billing instead: it lists your organizations, finds the one whose billing reports Copilot AI-credit usage, and shows **Org Credits** (credits the whole org used this month) and **Org Spend** (dollars billed beyond the included pool). Two caveats:
  - The numbers are **organization-wide**, not your personal share — GitHub doesn't expose per-seat usage.
  - Reading an org's billing requires you to be an **org owner or billing manager**. Regular members keep the previous behavior: the plan shows, the meters read "No data".
- Org Credits is shown as a plain count, not a percentage: the billing API reports usage only, never the org's credit allotment, and OpenUsage doesn't fabricate a denominator.

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
- **Meters show "No data" but the plan is shown** — expected on an org-managed Copilot Business/Enterprise seat when you aren't an owner or billing manager of the org (GitHub doesn't expose per-seat quota, and org billing is admin-only). If you *are* an org admin and still see no Org Credits, make sure your token can list your orgs — the GitHub CLI token from `gh auth login` can; some editor-plugin tokens can't.

## Under the hood

`GET https://api.github.com/copilot_internal/user` with the standard Copilot client headers (API version `2025-04-01`). The response reports each bucket as percent *remaining*; the meters show percent *used*.

For org-managed seats (identified by the token-based-billing placeholder in that response), the provider additionally calls the public REST billing API: `GET /user/orgs` to list your organizations, then `GET /orgs/{org}/settings/billing/usage/summary` per org until one reports Copilot AI-credit usage. The matching org is remembered, so steady-state refreshes make a single extra call; it's re-discovered automatically if it stops answering.
