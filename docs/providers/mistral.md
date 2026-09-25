# Mistral

Tracks [Mistral](https://mistral.ai) subscription usage: the included monthly **API** allowance and
the separate **Vibe Code** allowance, each as the percentage Mistral itself reports.

## What it tracks

| Metric | Meaning |
|---|---|
| API | The subscription's included monthly API allowance (percentage) |
| Vibe | The Vibe Code plan's monthly allowance (percentage) |

Both meters reset with the billing month; Mistral reports the reset date when it exposes one.

## Where credentials come from

Mistral publishes its included API and Vibe Code allowances only through the Admin console —
there is no companion CLI credential and no API-key endpoint for them — so OpenUsage reads the
web session you already have in a browser on this Mac. Nothing is pasted at first run and no login
flow runs. Sources are tried in this order:

1. `~/.config/openusage/mistral.json` — a saved full `Cookie:` header from a request to
   `admin.mistral.ai` (must contain an `ory_session_*` cookie; `csrftoken` enables the console
   fallback). This file wins over the browser reads, so it's also the override path.
2. Firefox's cookie store (plain-text values, any profile).
3. Chrome-family cookie stores (Chrome, Chromium, Brave, Edge, Arc) — values are decrypted with
   the browser's Keychain "Safe Storage" key. The first read can trigger a Keychain prompt for
   the browser's entry.

Only the `ory_session_*` and `csrftoken` cookies are ever sent, and only to Mistral's own console
domains. Safari isn't read (its cookie store needs Full Disk Access and a binary format
OpenUsage doesn't parse) — Safari users save the `Cookie:` header instead.

## Under the hood

Two console routes Mistral's own pages use (undocumented internal endpoints, stable in practice):

- `GET https://admin.mistral.ai/subscription` — the page's server-rendered data carries both
  allowances (`api_budget` / `vibe_budget`: `usage_percentage`, `initial_budget`, `currency`,
  `reset_at`). Best-effort; a failure falls back to the Vibe route.
- `GET https://admin.mistral.ai/api/local-trpc/billing.vibeUsage` — the Vibe percentage, used only
  when the subscription page reports no Vibe allowance. Needs `X-CSRFTOKEN`.

The reported percentage is the source of truth for each meter; the budget amount and currency
aren't metered. When the stream carries two different objects under one allowance name, neither is
taken (there is no telling which is this account's). With no allowance at all — an account
without a subscription — the card reads "No usage data" rather than erroring.

## Troubleshooting

- **"Sign in to admin.mistral.ai"** — no Mistral session was found. Sign in to
  [Mistral Admin](https://admin.mistral.ai/organization/usage) in your browser, or save a
  `Cookie:` header to `~/.config/openusage/mistral.json`.
- **"Your Mistral session expired"** — the console answered with a redirect to the login page or a
  401/403. Sign in again in the browser (the cookies are re-read on the next refresh).
- **"Couldn't read your browser's Mistral cookies"** — the browser's cookie store or Keychain
  entry exists but couldn't be read (permissions). Save a `Cookie:` header instead.
- **"No usage data"** — the session works, but the account reports no included allowance.
