# Refreshing & Caching

## When data updates

- All enabled providers refresh together: once at launch, then every 5 minutes (a fixed cadence — there's no setting for it). Opening the popover does not start a second automatic pass. Providers fetch in parallel — one slow provider doesn't delay the others.
- Turning a provider on (yourself in Customize, or automatically by first-launch/new-provider detection) fetches it promptly instead of waiting out the interval — even when the change lands in the middle of a refresh that's already running.
- The Dashboard and Settings footer shows `Next update in Nm`. **Clicking it (or pressing ⌘R while that footer is present)** refreshes immediately, skipping the cache.
- While a provider is fetching, a small spinner appears next to its name (and one shows in the footer beside the countdown), so you can tell a refresh is in flight rather than wondering if the numbers are stale.

## Caching

Snapshots are cached on disk and load instantly at launch, so you see your last-known values immediately instead of placeholders — even before the first fetch finishes.

A cached value only counts as *fresh* (skip-a-refresh fresh) when it was fetched **during the current running session**. So a value cached in an earlier session always re-fetches on the first pass after launch — you still see it instantly, but the app never waits out the old interval before getting live numbers. This matters after an update: a new app version refreshes right away instead of showing the previous version's data until its interval lapses. Within a session, a freshly fetched value then counts as fresh for one refresh interval before the next pass re-fetches it.

## When a fetch fails

A failed refresh **never wipes your data**: the last good values stay on screen, and a small warning triangle appears next to the provider's name — hover it for the error message (e.g. "Not logged in"). The error clears on the next successful refresh.

Rows that have never had data show "No data" rather than made-up numbers.

## Stale data

Because a failed refresh keeps the last good values on screen, those values can persist if refreshes keep failing — so a plan or limit that changed on the provider's side could otherwise keep showing the old figures indefinitely. To make that obvious, a small **"Outdated"** tag appears next to the provider's name once its data is more than a couple of refresh cycles old (about ten minutes); hover it for the precise age ("Last updated 3h ago"). The tag stays short so it never crowds a long plan name. When you see it, the numbers below are from that earlier time, not live — usually because the provider is failing to refresh (check the warning triangle) or the Mac was asleep. A successful refresh clears it.
