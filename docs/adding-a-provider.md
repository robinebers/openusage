# Adding a Provider

How to add a new AI provider to OpenUsage. Read the [architecture overview](architecture.md) first so the
pieces below make sense.

## What a provider is

A provider is a small Swift module under `Sources/OpenUsage/Providers/<Name>/` that conforms to
`ProviderRuntime`. It has three parts:

- an **auth store** that reads credentials from the provider's existing local login, or from a saved or
  environment-provided API key,
- a **usage client** that calls the provider's API,
- a **mapper** that turns the response into the app's metric vocabulary.

OpenUsage reuses a provider's existing local login whenever one is available. If the provider has no
companion CLI or app to reuse, it can opt into OpenUsage's per-provider API-key editor instead; see
[User-supplied API keys](#user-supplied-api-keys).

Besides `refresh()`, every provider implements `hasLocalCredentials()` — a cheap, local-only check
(files, databases, keychain, saved keys, and environment variables; never the network) for whether
those credentials exist at all. A fresh install probes
it once to turn on exactly the providers with credentials available locally (see `FirstRunSeeder`), and existing
installs probe it once on the first launch after your provider ships (see `NewProviderSeeder`) — so
implementing it correctly is what gets the new provider auto-enabled when credentials are available
locally (see [Which Providers Are On](provider-enablement.md)). Mirror the same credential sources
`refresh()` reads, and run blocking loads via `loadOffMainActor`. The shared load must distinguish a
credential that is genuinely absent from one that exists but cannot be read or parsed: return `nil` (or
an empty candidate list) only for proven absence, and throw after logging a safe source-only diagnostic
for unreadable or malformed data. Since detection runs once, `hasLocalCredentials()` returns `true`
conservatively when that load throws; the provider is then enabled and its normal refresh shows the user
the repairable error instead of silently leaving it off.

## The metric contract

`refresh()` returns a `ProviderSnapshot` whose `lines` are `MetricLine` values. Pick the case by the shape
of the number, not by the provider:

- **`.progress`** — a bounded meter with `used`, `limit`, and a `format`:
  - `.percent` for quota-style limits (session, weekly),
  - `.dollars` for a capped dollar amount (credits with a ceiling),
  - `.count(suffix:)` for a capped count (e.g. requests per cycle).
  - Add `resetsAt` when the window resets at a known time, and `periodDurationMs` for the cycle length.
- **`.values`** — an unbounded row carrying one or more raw numbers (each a `MetricValue`: a number, its
  kind, an optional unit label like `"tokens"`). Use it for any limitless numeric row — a spend day carries
  dollars *and* tokens, Codex credits carry dollars *and* a count. The widget picks which to show
  (cost-only, tokens-only, or both) via its descriptor, and formatting happens at the display edge, so the
  menu bar never re-parses a string. Prefer this for numbers.
- **`.text`** — a value shown as-is, like `$12.34 spent`. Use it only for genuinely string-y rows, or a
  capped dollar amount whose limit lives on the descriptor.
- **`.badge`** — a short status pill, like `Disabled` or a pay-as-you-go cap. Use it for state rather than
  a fillable number.

Set the snapshot's `plan` when the provider exposes a plan name. On failure, return
`ProviderSnapshot.error(provider:error:)` with a typed provider error when possible, so telemetry can group
the failure by a stable, non-private reason such as "not logged in" or "network". Use the message-only
factory only when there is no typed error, and never return stale or empty data silently.

## Steps

1. **Check first.** Look at open issues and `docs/providers/` to see if the provider is already requested
   or in progress.
2. **Create the module.** Add `Sources/OpenUsage/Providers/<Name>/` with the auth store, usage client, and
   mapper, conforming to `ProviderRuntime` — both `refresh()` and `hasLocalCredentials()` (the compiler
   enforces the latter; there is no default). Reuse the same throwing auth-store load in both paths — don't
   write a second credential-reading path. A missing source returns no value; a present-but-unreadable or
   malformed source logs and throws, which the nonthrowing probe maps to `true` conservatively while
   `refresh()` maps it to a friendly typed error. Reuse the
   shared helpers in `Support/` (`ProviderParse` for JSON/number/percent parsing, `OpenUsageISO8601` for
   timestamps) instead of copying them.
3. **Declare its widgets.** Expose the provider's metrics as `WidgetDescriptor`s using the factories in
   `WidgetDescriptor+Factories.swift` (`percent`, `boundedDollars`, `spend`, `tokenSpend`, `combined`, `values`, `badge`, and so on).
4. **Register it.** Add the provider to the list in `AppContainer`.
5. **Test it.** Add focused tests under `Tests/OpenUsageTests/`, including a mapper test that feeds a
   sample API response and checks the resulting metric lines.
6. **Document it.** Add a page under `docs/providers/` covering what it tracks, where its credentials come
   from, the endpoints it calls, and what its error states mean.
7. **Run it.** Build and launch with `./script/build_and_run.sh` and confirm the provider shows up.

## Conventions

- Validate only at the boundary (the API response); trust the app's internal types.
- Match the metric labels and units the provider's own dashboard uses, so numbers are recognizable.
- Declare the provider's **quick links** on its `Provider` value (`links:`). Each link is a `ProviderLink(label:url:)` rendered as a button in the card's expanded area that opens the URL in the default browser. Ship the provider's own Status / Console / Dashboard pages where they exist; leave `links` off (it defaults to empty) for providers without any. Cap at **two** links per provider (standard labels: Status, Dashboard, API Keys, or Usage). Only `http(s)` URLs with a non-empty label render.

## User-supplied API keys

Most providers read credentials already on the machine (a companion CLI/app's session, the keychain).
A provider with nothing reusable — currently OpenRouter and Z.ai — conforms to `APIKeyManaging`. Its
**Customize → provider → API Key** section then manages the key without a provider-specific view:

- The auth store exposes one atomic `APIKeyEditorSnapshot` (source status plus revealable key) and
  `saveAPIKey(_:)` / `deleteAPIKey()` operations that write to a config file it already reads.
  Config-file precedence over the environment makes a saved key an override for free. A config that
  cannot be read or parsed logs only its path and records `savedKeyError`; reveal returns no fallback
  key under that status, so the editor never mislabels an environment or alternate-file fallback.
- The refresh load is throwing: missing files and blank environment values are absent, while unreadable
  and malformed present files become friendly typed errors. Continue through the declared config/env
  sources first — any valid fallback wins, and the stored boundary error surfaces only when no usable
  key loads. The one-shot `hasLocalCredentials()` probe treats that thrown case conservatively as present.
- The provider conforms by delegating those operations to its auth store.
- `AppContainer` collects every `APIKeyManaging` provider into `apiKeyProviders`; the matching
  provider detail displays the editor automatically. Add the provider to the registry as usual and
  the Customize screen picks it up.

Persist the key to a file the auth store already checks (don't introduce a parallel store), so the
file remains the source of truth and a user can still edit it by hand.
