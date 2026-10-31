# Architecture

OpenUsage is a SwiftPM package with three targets: `OpenUsage` (the library, where everything lives),
`OpenUsageApp` (a thin executable), and `OpenUsageCLI` (the `openusage` command, shipped at
`Contents/Helpers/openusage`). Swift 6 with strict concurrency; SwiftUI content hosted in an
AppKit-owned status item and panel.

## Composition root

`AppDelegate` (`App/OpenUsageApp.swift`) acquires the single-instance lock, applies the appearance
setting, builds `AppContainer`, starts the refresh loop, imports the OpenRouter and Z.ai keys 0.7.x
saved, once (`Stores/APIKeyV1Files.swift`), creates `StatusItemController`, and starts
the Sparkle updater.

`AppContainer` (`App/AppContainer.swift`) owns the long-lived stores and is injected into the SwiftUI
environment:

| Store | Owns |
|---|---|
| `AccountStore` | The list of `Account` values (`id`, `kind`, `label`, `hub`, `addedAt`), persisted under `accounts.v1`; the connected `CLIProxyHub` values under `cliproxyHubs.v1`; and the `CredentialVault`. |
| `CLIProxyHubSync` | Each CLIProxyAPI hub's last read, and the reads that keep its mirrored accounts in step with its login list. |
| `LayoutStore` | Provider order, metric order and visibility, menu-bar stars, and undo history, saved as one `LayoutState`. A provider's only account starts from that provider's 0.7.x layout, which `LayoutV1Keys` reads. |
| `PopoverState` | The popover's screen, the Accounts detail and Add Account sheet, the screen-slide bookkeeping, and the transient pills (star denial, Copied, the Accounts star notice). |
| `WidgetDataStore` | The latest `ProviderSnapshot` per account, the refresh loop's per-account outcomes, errors, and staleness. |
| `AccountRenameStore` | Which account name is being edited. |
| `TelemetryRecorder` | The daily ping and per-provider rollups (see `Services/Telemetry.swift`). |
| `HideFromScreenShareSetting` | The Hide From Screen Share switch and, while it is on, whether the screen is being captured (`Services/ScreenCaptureProbe.swift`). |

Accounts are the source of truth. Every `AccountStore` change runs `AppContainer.syncAccounts`
synchronously, which rebuilds the runtimes with `ProviderCatalog.make(accounts:vault:http:reusing:)`,
applies the new `WidgetRegistry` to the layout and data store in place (a removed account's in-flight
refresh is cancelled there, so a late response has nothing to commit to), and refreshes any account whose
runtime is new: a new account, or a hub account whose link to its hub changed. The status item and the panel are never rebuilt on an account change.

## Accounts and sign-in

`ProviderKind` (`Models/Account.swift`) is the enum of providers. It carries each provider's display
name, icon, quick links, and `authMethod` (OAuth or an API key with its key page).

`AccountStore.load` decodes each entry of `accounts.v1` on its own. An entry this build cannot decode,
such as one whose `kind` is a provider it lacks, is logged and kept as its JSON value, and every save
writes it back after the known accounts.

`ProviderLogin` (`Services/ProviderLogin.swift`) is the sign-in contract: `login(prompt:pastedCode:)`
drives a browser, token-page, or device-code prompt and returns the account's label and credential.
`ProviderLoginCatalog` maps a kind to its login. Browser logins live in
`Services/BrowserProviderLogins.swift` (Claude, Codex, Antigravity) and use `LoopbackCallbackServer`
and `PKCE`; device-code logins and the Cursor and API-key logins live in
`Services/DeviceProviderLogins.swift`. Devin's login opens a page that shows a token for the user to
paste, and lives in `Providers/Devin/DevinLogin.swift`. `AddAccountFlow` runs a login for the
`AddAccountSheet`.

`CredentialVault` (`Services/AccountCredentialVault.swift`) stores one `AccountCredential` (OAuth
tokens or an API key) per account id in the app's Keychain service.

A CLIProxyAPI hub (`Models/CLIProxyHub.swift`) is not a provider. Each supported login on it is
an ordinary account of its provider (`.claude`, `.codex`, `.antigravity`, `.devin`, or `.grok`) whose
`hub` link names the hub and the login's `auth_index`;
its stored credential is the literal `$TOKEN$` with no refresh token, and the hub's management key is
stored under the hub's id. `ProviderCatalog` gives such an account a `HubTunnel`
(`Services/CLIProxyHubClient.swift`) as its `HTTPClient`, which wraps each request in the hub's
`POST /v0/management/api-call` and unwraps the upstream answer, so the providers' own clients,
mappers, and refresh code run unchanged. `CLIProxyHubGate` sends a hub one request at a time and stops
calling it after a rejected key or an IP ban. `AccountStore.mirror` reconciles the accounts with the
hub's `auth-files` listing, and applying the same listing twice changes nothing.

## Usage

`AccountProviderRuntime` (`Providers/AccountProviderRuntime.swift`) is the one `ProviderRuntime`.
There is one per account. It declares the account's `widgetDescriptors` (the metrics its card can
show, prefixed with the account's `cardID`), loads the credential from the vault, calls the provider's
usage client, maps the response to `MetricLine` values, and returns a `ProviderSnapshot`. Token
refresh, Claude's per-login session (`ClaudeSession`: the saved 429 window, the shared usage read,
the hourly plan and reset-grant reads), and the reset-claim services live in its extensions under
`Providers/<Name>/`. Each provider folder holds a `<Name>UsageClient` (HTTP) and a
`<Name>UsageMapper` (pure response-to-metrics mapping).

`WidgetRegistry.from(providers)` collects every descriptor. `LayoutStore` keeps which ones the user hid
and their order; `WidgetDataStore` turns snapshots into `WidgetData` for the views.

## Refresh loop

`AppContainer.startRefreshing` runs `WidgetDataStore.refreshAll`, then `QuotaNotificationEvaluator.evaluate` over the shown metrics, then
`TelemetryRecorder.tick`, at launch and then every `RefreshSetting.interval` (5 minutes), with
`WidgetDataStore.refreshHourlyReads` halfway between passes for the reads a provider must not get in
the same burst as usage (`ProviderRuntime.refreshHourlyReads`; Claude's plan and reset grants). Each
account's hourly reads get the same two-minute deadline as its refresh, so one that hangs never holds up
the loop. Every cadence and wait is a named constant in `RefreshSetting`. ⌘R runs `refreshAll(force: true)`, which skips the
cache and asks each runtime's hourly reads again (`ProviderRuntime.forgetHourlyReads`); whether a
forced refresh waits out a backoff is `RefreshBackoff.holds`.
`refresh(providerID:)` skips an account whose snapshot is less than an interval old, honours its `RefreshBackoff`,
and a two-minute deadline per account, and reports each real outcome through `onRefreshOutcome`. Each
fetched snapshot is written to the cache as it lands.

## Command line

`OpenUsageCLI` parses its arguments, finds the app bundle it ships inside (`AppBundleLocator`,
`ContainingAppBundle`) to open that app's defaults domain, and hands the rest to `UsageReader` in the
library. `UsageReader` builds a `WidgetRegistry` from the stored accounts (`AccountStore.load`) with
the same `AccountProviderRuntime.provider(for:)` and `widgetDescriptors(for:)` the app's runtimes use,
and `LimitsEnvelope` projects it and the snapshot cache into the `openusage.limits.v1` JSON that
`exportingLimit` declares resource by resource. Each entry's `displayName` is the account's
`Provider.fullName`, and its `stale` and `expiresAt` come from `ProviderSnapshot.isStale(at:)` and
`staleAt`, the rule `WidgetDataStore.stalenessHint` uses for the account's clock. The command never
refreshes and never opens the Keychain.
`CommandLineToolInstaller` is the Settings-side symlink installer.

## Views

`StatusItemController` (`App/StatusItemController.swift`) owns the `NSStatusItem` and the
`MenuBarPanel`, a key-capable `NSPanel` that hosts `DashboardView`, and renders the menu-bar strip
with `MenuBarStripRenderer`. `PanelHeightController` sizes the panel to its content.

`DashboardView` switches between the dashboard (`DashboardContentView` → `WidgetGroupedListView` →
`DashboardProviderSection` → `DashboardLiveRow` → `DashboardMetricRow`; the share image and the drag
previews draw the same rows through the static `DashboardAccountRows`), Accounts
(`AccountsView` → `AccountListView` and `AccountDetailView`), and `SettingsScreen`. Right-click
menus are declared as data in `DashboardMenus` and rendered by `ClosureMenuItem`.
`ShareCardRenderer` renders a provider card into the branded PNG behind **Share Screenshot**.

## Updates and telemetry

`UpdaterController` wraps Sparkle. It starts only when the bundle declares `SUFeedURL`, which only
`script/release.sh` writes, so the dev build never checks for updates. See [Updates](updates.md).

`PostHogTelemetrySink` and `TelemetryRecorder` send the anonymous daily ping,
crash reports, and the optional provider rollups described in [Privacy](privacy.md). Ids are
kind-scoped (`WidgetDescriptor.kindScopedKey`), so events name providers, never accounts.

## Logging

`AppLog` writes to unified logging only, subsystem `OpenUsage`, one category per `LogTag`. Every
message passes `LogRedaction` first. See [Debugging](debugging.md).
