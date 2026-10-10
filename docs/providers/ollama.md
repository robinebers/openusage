# Ollama

Tracks [Ollama Cloud](https://ollama.com) plan usage — the credits and limits Ollama shows on its own
settings page.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Legacy plans: 5-hour window usage (percentage of your plan's allowance), with a reset countdown |
| Weekly | Legacy plans: 7-day window usage (percentage of your plan's allowance), with a reset countdown |
| Monthly | Current plans: dollars of your monthly included credits used, with a countdown to the monthly reset |
| Purchased Credits | Dollars left of the extra credits you bought, which are used after your included credits run out |

Ollama's current plans come with a monthly dollar allowance; plans from before that change keep their
session and weekly limits instead. Each account reports one or the other, so OpenUsage shows whichever
your plan has and leaves the other rows out.

Your plan (Free, Pro, Max) is shown beside the provider name. If Ollama can't tell OpenUsage which plan
you're on, the badge is left off and the card explains why — the meters keep working either way.

Session, Weekly, and Monthly are always visible, and Monthly starts pinned to the menu bar. On a legacy
plan, star Session or Weekly in **Customize** to put them there. Purchased Credits sits behind the
provider's caret — you can move any of them in **Customize**. Local models don't count toward these
limits; only cloud models do.

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

The credits or limits Ollama reports for your account appear on the next refresh.

## Under the hood

Two ollama.com endpoints, both authenticated with a signature from your local Ollama key:

- [`GET https://ollama.com/api/balance`](https://docs.ollama.com/api/balance) — included credits
  (`balance_usd` left of `allowance_usd`, plus the billing `period`) or, on legacy plans, `session` and
  `weekly` limits as `remaining_percent` with `resets_at`; plus `purchased.balance_usd`.
- `POST https://ollama.com/api/me` — the plan name (best-effort; a failure here doesn't blank the meters).

Each request carries an `Authorization` header of `<public key>:<signature>`, signing the string
`<METHOD>,<request-uri>` where the URI includes a `ts` unix-seconds parameter — the same scheme the
Ollama CLI uses, so a captured header can't be replayed later. Ollama allows 10 balance requests a minute.

Ollama reports what *remains*; OpenUsage shows what's used (Monthly used = allowance − balance; Session
used = 100% − remaining). A meter that isn't in the response is omitted from the API and shows "No data"
if its dashboard row is enabled, rather than being shown as zero usage. A response with no included
credits or limits OpenUsage can read is reported as an invalid response.

## Troubleshooting

- **"No Ollama key found"** — Ollama has never run on this Mac. [Install it](https://ollama.com/download)
  and run `ollama signin`.
- **"Not signed in to Ollama Cloud"** — Ollama is installed but the key isn't linked to an account.
  Run `ollama signin`.
- **"Couldn't read ~/.ollama/id_ed25519"** — the key file exists but isn't readable. Check its
  permissions (it should be owned by you, mode `600`).
- **"Couldn't read your Ollama plan"** (an amber notice by the name) — the plan badge is missing because
  Ollama either didn't answer that request or answered with something OpenUsage couldn't read. Your
  meters are unaffected and still current; the badge comes back on its own once Ollama answers normally.
- **"Usage response invalid"** — Ollama answered, but without credits or limits OpenUsage can read.
  Check your usage at [ollama.com/settings](https://ollama.com/settings).
