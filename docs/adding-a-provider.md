# Adding a Provider

How to add a new AI provider to OpenUsage. Read the [architecture overview](architecture.md) first so the
pieces below make sense.

## What a provider is

A provider is a small Swift module under `Sources/OpenUsage/Providers/<Name>/` that conforms to
`ProviderRuntime`. It has three parts:

- an **auth store** that reads credentials already on the user's machine (config files, keychain),
- a **usage client** that calls the provider's API,
- a **mapper** that turns the response into the app's metric vocabulary.

OpenUsage never asks the user to paste a token — if the provider's own CLI or app has already logged in,
OpenUsage reads those existing credentials.

## The metric contract

`refresh()` returns a `ProviderSnapshot` whose `lines` are `MetricLine` values. Pick the case by the shape
of the number, not by the provider:

- **`.progress`** — a bounded meter with `used`, `limit`, and a `format`:
  - `.percent` for quota-style limits (session, weekly),
  - `.dollars` for a capped dollar amount (credits with a ceiling),
  - `.count(suffix:)` for a capped count (e.g. requests per cycle).
  - Add `resetsAt` when the window resets at a known time, and `periodDurationMs` for the cycle length.
- **`.text`** — an unbounded value shown as-is, like `$12.34 spent`. Use it when there's no limit to draw a
  bar against.
- **`.badge`** — a short status pill, like `Disabled` or a pay-as-you-go cap. Use it for state rather than
  a fillable number.

Set the snapshot's `plan` when the provider exposes a plan name. On failure, return
`ProviderSnapshot.error(provider:message:)` with a friendly message — never return stale or empty data
silently.

## Steps

1. **Check first.** Look at open issues and `docs/providers/` to see if the provider is already requested
   or in progress.
2. **Create the module.** Add `Sources/OpenUsage/Providers/<Name>/` with the auth store, usage client, and
   mapper, conforming to `ProviderRuntime`. Reuse the shared helpers in `Support/` (`ProviderParse` for
   JSON/number/percent parsing, `OpenUsageISO8601` for timestamps) instead of copying them.
3. **Declare its widgets.** Expose the provider's metrics as `WidgetDescriptor`s using the factories in
   `WidgetDescriptor+Factories.swift` (`percent`, `boundedDollars`, `spend`, `badge`, and so on).
4. **Register it.** Add the provider to the list in `AppContainer`.
5. **Test it.** Add focused tests under `Tests/OpenUsageTests/`, including a mapper test that feeds a
   sample API response and checks the resulting metric lines.
6. **Document it.** Add a page under `docs/providers/` covering what it tracks, where its credentials come
   from, the endpoints it calls, and what its error states mean.
7. **Run it.** Build and launch with `./script/build_and_run.sh` and confirm the provider shows up.

## Conventions

- Validate only at the boundary (the API response); trust the app's internal types.
- Match the metric labels and units the provider's own dashboard uses, so numbers are recognizable.
