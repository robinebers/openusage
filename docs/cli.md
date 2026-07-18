# Command-Line Interface

OpenUsage ships a one-shot `openusage` command for agents and scripts. It prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits; it never launches or leaves the menu-bar
app running. The output contains stable scalar limits and balances, not UI rows, colors, subtitles,
charts, or spend-history tiles.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` is the CLI equivalent of the app's manual refresh: it bypasses that freshness gate and
writes successful results to the same cache. Credentials are used locally and never appear in the output.

## Claim a Codex Reset Credit

`openusage codex --claim-reset` claims a Codex rate-limit reset credit — the same claim the app offers
from its resets popover, sharing the app's credential handling and idempotency key handling, so the
retries *within* one invocation (credential fallback) can never spend a second credit. The command
fetches the current credit list fresh, claims the credit closest to expiry, refreshes Codex through the
shared cache so the app and later reads reconcile, and prints a JSON outcome:

```sh
openusage codex --claim-reset
# {"creditExpiresAt":"2026-07-19T04:00:00Z","provider":"codex","redeemRequestID":"…","schema":"openusage.claim.v1","status":"claimed"}
```

`status` is `claimed`, `nothing_to_reset` (usage doesn't need a reset right now — the credit is kept),
`no_credit` (nothing claimable: already claimed elsewhere or expired), or `failed`. `creditExpiresAt`
identifies the credit that was targeted and is omitted when none was. Exit codes: `0` for `claimed` and
`nothing_to_reset`, `3` for `no_credit`, `4` for `failed`. Post-claim refresh problems appear as
`openusage: warning:` lines on stderr and never change the exit code — the claim already landed.

Each invocation is its own claim with a fresh idempotency key, so don't retry `--claim-reset` blindly in
a script: a `failed` claim whose request never got an answer may still have landed server-side, and a
re-run would target the next credit. Re-read the credit list first (`openusage codex --force`) and only
claim again if a credit you expected gone is still there.

This is the CLI's only write; every other command is read-only.

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside OpenUsage, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments, `3` when a requested provider has no snapshot
(or a claim finds no credit), and `4` when a claim, refresh, or local read fails — except a *post-claim*
refresh problem, which stays a stderr warning.
