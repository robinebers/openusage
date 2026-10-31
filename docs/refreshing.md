# Refreshing

## When data updates

| Trigger | What refreshes |
| --- | --- |
| Launch | Every account whose saved values are 5 minutes old or more |
| Every 5 minutes | Every account, whatever you are doing, so the menu bar stays current; a pass whose time came while the Mac slept runs as soon as it wakes |
| Adding an account | That account |
| **⌘R**, or clicking the footer's **Next update in …** | Every account, skipping the cache, the hourly reads and the wait after a failure, never a wait the provider asked for |
| An account's **Refresh** menu item | Its accounts, the same way as ⌘R |
| Claiming a rate-limit reset | That account, right after the result shows |

There is no setting for the interval. A wait a provider asked for (HTTP 429) holds for every trigger,
⌘R included. Accounts fetch in parallel, so a fast provider never waits for a slow one. Each account's
result shows and is saved as soon as it lands. While an account is fetching, a spinner shows next to
its name and in the footer.

## Caching

Usage is read on every refresh. Reads that rarely change are read at most once an hour and reused in
between: the plan name (Claude, Cursor, Grok, Ollama, Z.ai, and Antigravity's Cloud Code project),
Cursor's membership (Enterprise, Team, or a personal plan), ChatGPT's list of reset credits with their
expiry times (the count still updates every refresh), and Claude's reset grants. ⌘R reads them all again at once, so a plan upgrade shows within an hour, or on
the next ⌘R. Claude's plan and reset grants are read halfway between two passes, never together with
its usage, and ⌘R reads the reset grants again only once their last check is 15 minutes old.
Cursor's usage history is read a day at a time: today and yesterday on every refresh, and each older
day until one read of it succeeds (see [Cursor](providers.md#cursor)). Ollama's usage history is read
once an hour, at the start of a UTC day, and on ⌘R (see [Ollama](providers.md#ollama)).

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
`Retry-After` header asks, up to an hour, or on the same doubling schedule when it names no wait. The last good values
stay on screen with the clock icon, whose tooltip names the time of the next try, for example "Claude
asked OpenUsage to wait. Retrying at 14:32." A manual refresh does not ask before that time.

Claude budgets requests per Anthropic login, so its wait covers the whole login: every card signed in
to it, its usage, plan and reset-grant reads, and the refresh after a claim. When Claude names no wait
(or a wait of 0), the first wait is 5 minutes and each 429 in a row doubles it, up to an hour. The wait
is saved, so a relaunch inside it sends Claude nothing and shows the same "Retrying at" time. Two cards
signed in to the same Claude login share one usage request per pass.

An account that stops responding is given up on after two minutes. Its spinner stops, the warning reads
"Refresh timed out after 120s", and it is tried again on a later pass.

Once an account's values are more than two refresh cycles old, a clock appears next to its name, and
the account's right-click menu starts with their age. A successful refresh clears it. The
[`openusage` command](cli.md) marks the account `"stale": true` at the same moment.

## Expired sign-ins

OAuth accounts renew their own sign-in with the provider's refresh token, 5 minutes before the
provider's expiry (the margin Claude Code uses), so a refresh never sends a token that is about to
expire. Cursor renews its sign-in in the last 7 days of its 60-day token. When Claude, ChatGPT, Grok or
Antigravity refuses the access token anyway (a 401 on the usage read, for an expiry the sign-in never
reported or one the provider cut short), the sign-in is renewed once and the read retried.

The warning says the sign-in expired when the usage read still refuses the token, or when the provider
refuses the renewal itself: an `invalid_grant` answer, one of ChatGPT's own refresh-token errors, or
Cursor asking OpenUsage to sign out. Remove the account and add it again to sign in afresh.

A renewal that fails for any other reason, such as an outage (HTTP 5xx), a rate limit (HTTP 429), or no
connection, does not mean the sign-in expired. While the current token still works, the account keeps
using it and tries the renewal again on the next pass, or after the provider's `Retry-After` when a
rate limit sends one. Once the token has expired, the refresh fails
with that error and is tried again like any failed fetch (see [When a fetch fails](#when-a-fetch-fails)).

When the Keychain refuses to save a renewed sign-in, the account keeps the new tokens in memory, logs
the error, and tries the save again on the next pass, so it never sends a refresh token the provider
already replaced.
