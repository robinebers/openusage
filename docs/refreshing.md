# Refreshing

OpenUsage refreshes every account every 5 minutes. There is no setting for the interval.

## When data updates

| Trigger | What refreshes |
| --- | --- |
| Launch | Accounts whose saved values are 5 minutes old or more |
| Every 5 minutes | Every account. A pass missed during sleep runs on wake |
| Adding an account | That account |
| **⌘R**, or clicking **Next update in …** | Every account, skipping the cache and the wait after a failure |
| An account's **Refresh** menu item | Its accounts, like ⌘R |
| Claiming a rate-limit reset | That account |
| Launch, opening Accounts, and hourly | Each [CLIProxyAPI hub](cliproxyapi.md#staying-in-sync)'s login list |
| Replacing a hub's management key | Every account from that hub |

A wait a provider asked for (HTTP 429) holds even for ⌘R. Accounts fetch in parallel.

## Caching

Usage is read on every refresh. These reads happen at most once an hour, and on ⌘R:

- The plan name, and Cursor's membership.
- ChatGPT's reset credits. The count still updates every refresh.
- Claude's reset grants. ⌘R rereads them only after 15 minutes.

Usage history:

- [Cursor](providers.md#cursor) reads today and yesterday every refresh, and each older day until
  one read of it succeeds.
- [Ollama](providers.md#ollama) and [ChatGPT](providers.md#chatgpt) read it hourly, at the start
  of a UTC day, and on ⌘R.

The last values are saved on disk and shown at launch. They stay fresh for 5 minutes, across a
relaunch too.

## When a fetch fails

A failed refresh keeps the last good values. The account shows under **Needs Attention** in
Priority, and **Fix** opens its page with the reason. The next successful refresh clears the error.

An account that failed waits before the next try:

- 5 minutes, doubling with each failure in a row, up to an hour.
- One request an hour if its key or sign-in keeps being refused.
- No extra wait if it never reached the provider, such as with no internet.
- A manual refresh skips the wait.

When a provider rate-limits OpenUsage (HTTP 429, or GitHub's HTTP 403), the account waits as long as
`Retry-After` asks, up to an hour, or on the doubling schedule. Claude's wait covers every card
signed in to the same Anthropic login, and survives a relaunch.

An account that doesn't answer within two minutes shows "Refresh timed out after 120s" and is tried
again on a later pass.

Values more than two refresh cycles old get a clock next to the account's name, and the
[`openusage` command](cli.md) marks them `"stale": true`.

## Expired sign-ins

OAuth accounts renew their sign-in 5 minutes before it expires. Cursor renews in the last 7 days of
its 60-day token. If Claude, ChatGPT, Grok, or Antigravity refuses the token anyway (HTTP 401),
OpenUsage renews once and retries.

If the provider still refuses the token or refuses the renewal, the warning says the sign-in
expired. Use **Sign In Again…** on the account's page.

Other renewal failures, such as an outage, a rate limit, or no connection, don't mean the sign-in
expired. The account keeps its current token while it works and retries the renewal on the next
pass. Once the token expires, the refresh fails like any [failed fetch](#when-a-fetch-fails).
