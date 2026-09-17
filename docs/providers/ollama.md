# Ollama

Tracks [Ollama Cloud](https://ollama.com) plan usage — the session, weekly, and monthly limits Ollama
shows on its own settings page.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour window usage (percentage of your plan's allowance) |
| Weekly | 7-day window usage (percentage of your plan's allowance) |
| Monthly | Monthly usage (percentage of your plan's allowance), when reported for your account |
| Last 4 Weeks | Charges beyond your plan over the last four weeks. $0.00 on a subscription; real amounts for pay-as-you-go and API-key usage |

Your plan (Free, Pro, Max) is shown beside the provider name.

Session, Weekly, and Monthly are always visible; Session and Weekly start pinned to the menu bar.
Monthly starts unpinned and follows Weekly. Last 4 Weeks sits behind the provider's caret — you can
move any of them in **Customize**. A $0.00 on that row means no extra charges,
not an idle month: usage inside your plan's allowance is counted by the limit meters.

The session window is 5 hours and the weekly window is 7 days, but Ollama reports only how much of each
window you have used — never when the current one started or ends. These meters therefore show no reset
countdown, rather than a guessed one. Monthly also has no reset countdown. Local models don't count
toward these limits; only cloud models do.

## Where credentials come from

Nothing to paste. Ollama creates a signing key at `~/.ollama/id_ed25519` the first time it runs, and
`ollama signin` links that key to your ollama.com account. OpenUsage reads the key, signs each request
with it exactly as the Ollama CLI does, and never sends the key anywhere — only the signature goes out.

Because that key exists whether or not you've signed in, OpenUsage can tell only that Ollama is
installed — not that Ollama Cloud is set up. So Ollama never switches itself on, even when the key is
there: if you use Ollama for local models alone, it stays out of your way instead of showing you a
sign-in warning for a product you don't use. Turn it on in **Customize** when you want it.

## Setup

1. Install [Ollama](https://ollama.com/download) and create an account for a [cloud plan](https://ollama.com/pricing),
   including Free.
2. Sign in:

```bash
ollama signin
```

3. Turn **Ollama** on in **Customize** — unlike most providers, it never enables itself (see above).

The limits Ollama reports for your account appear on the next refresh. Free accounts can report a
Monthly limit without Session or Weekly limits.

## Under the hood

Two ollama.com endpoints, both authenticated with a signature from your local Ollama key:

- `GET https://ollama.com/api/usage` — the session, weekly, and monthly meters plus recent activity spend.
- `POST https://ollama.com/api/me` — the plan name (best-effort; a failure here doesn't blank the meters).

Each request carries an `Authorization` header of `<public key>:<signature>`, signing the string
`<METHOD>,<request-uri>` where the URI includes a `ts` unix-seconds parameter — the same scheme the
Ollama CLI uses, so a captured header can't be replayed later.

The usage endpoint is undocumented (it backs Ollama's own settings page), so OpenUsage reads it
defensively: `usage` is a fraction (`0.349` → 34.9%) and `cost` is a decimal string; a limit that isn't
in the response is omitted from the API and shows "No data" if its dashboard row is enabled, rather
than being shown as zero usage. A response with no `limits` at all is reported as an invalid response.

## Troubleshooting

- **"No Ollama key found"** — Ollama has never run on this Mac. [Install it](https://ollama.com/download)
  and run `ollama signin`.
- **"Not signed in to Ollama Cloud"** — Ollama is installed but the key isn't linked to an account.
  Run `ollama signin`.
- **"Couldn't read ~/.ollama/id_ed25519"** — the key file exists but isn't readable. Check its
  permissions (it should be owned by you, mode `600`).
- **Meters show "No usage data"** — you're signed in, but Ollama returned no limits for the account yet.
  Check your usage at [ollama.com/settings](https://ollama.com/settings).
