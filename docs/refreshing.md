# Refreshing

## When data updates

| Trigger | What refreshes |
| --- | --- |
| Launch | Every account whose saved values are 5 minutes old or more |
| Every 5 minutes | Every account, whatever you are doing, so the menu bar stays current |
| Adding an account | That account |
| **⌘R**, or clicking the footer's **Next update in …** | Every account, skipping the cache, the hourly reads and the wait after a failure |
| An account's **Refresh** menu item | Its accounts, the same way as ⌘R |
| Claiming a rate-limit reset | That account |

There is no setting for the interval. A wait a provider asked for (HTTP 429) holds for every trigger,
⌘R included. Accounts fetch in parallel, so a fast provider never waits for a slow one. Results that
land close together are grouped so a burst shows as one update and is saved once. While an account is
fetching, a spinner shows next to its name and in the footer.

## Caching

Usage is read on every refresh. Reads that rarely change are read at most once an hour and reused in
between: the plan name (Claude, Cursor, Grok, Ollama, Z.ai, and Antigravity's Cloud Code project),
Codex's list of reset credits with their expiry times (the count still updates every refresh), and
Claude's reset grants. ⌘R reads them all again at once, so a plan upgrade shows within an hour, or on
the next ⌘R.

The last snapshot of every account is saved on disk and shown at launch, so you see your last-known
values before the first fetch finishes. A value counts as fresh for one interval (5 minutes) after it
was fetched, across a relaunch too: relaunching within 5 minutes of a refresh asks no provider until
the next pass.

## When a fetch fails

A failed refresh never wipes your data. The last good values stay on screen and a warning icon appears
next to the account's name; the account's right-click menu starts with the reason. The
error clears on the next successful refresh.

An account that failed waits before it is tried again: 5 minutes after the first failure, then twice
as long after each further failure in a row, up to an hour. An account whose key or sign-in keeps
being refused drops to one request an hour. A failure that never reached the provider (no internet)
is tried again on the next pass without growing the wait. A successful refresh ends the wait, and a
manual refresh skips it.

When a provider rate-limits OpenUsage (HTTP 429), the account waits as long as the provider's
`Retry-After` header asks, or on the same doubling schedule when it names no wait. The last good values
stay on screen with the clock icon, whose tooltip names the time of the next try, for example "Claude
asked OpenUsage to wait. Retrying at 14:32." A manual refresh does not ask before that time.

An account that stops responding is given up on after two minutes. Its spinner stops, the warning reads
"Refresh timed out after 120s", and it is tried again on a later pass.

Once an account's values are more than two refresh cycles old, a clock appears next to its name, and
the account's right-click menu starts with their age. A successful refresh clears it.

## Expired sign-ins

OAuth accounts renew their own sign-in with the provider's refresh token, 5 minutes before the
provider's expiry (the margin Claude Code uses), so a refresh never sends a token that is about to
expire. Cursor renews its sign-in in the last 7 days of its 60-day token. When a provider rejects the renewal, the account shows a
warning with the reason. Remove the account and add it again to sign in afresh.
