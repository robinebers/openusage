# Architecture

OpenUsage is a SwiftPM package with three targets: `OpenUsage` (the library, where everything lives),
`OpenUsageApp` (a thin executable), and `OpenUsageCLI` (the `openusage` command, shipped at
`Contents/Helpers/openusage`). Swift 6 with strict concurrency; SwiftUI content hosted in an
AppKit-owned status item and panel.

## Composition root

`AppDelegate` (`App/OpenUsageApp.swift`) acquires the single-instance lock, applies the appearance
setting, builds `AppContainer`, starts the refresh loop, creates `StatusItemController`, and starts
the Sparkle updater.

`AppContainer` (`App/AppContainer.swift`) owns the long-lived stores and is injected into the SwiftUI
environment:

| Store | Owns |
|---|---|
| `AccountStore` | The list of `Account` values (`id`, `kind`, `label`, `addedAt`), persisted under `accounts.v1`, and the `CredentialVault`. |
| `LayoutStore` | Provider order, metric order and visibility, menu-bar stars, and undo history. It forwards screen routing to `PopoverNavigationStore`. |
| `WidgetDataStore` | The latest `ProviderSnapshot` per account, the refresh loop's per-account outcomes, errors, staleness, and the notification evaluator. |
| `NotificationSettingsStore` | The three notification toggles. |
| `AccountRenameStore` | Which account name is being edited. |
| `TelemetryRecorder` | The daily ping and per-provider rollups (see `Services/Telemetry.swift`). |

Accounts are the source of truth. Every `AccountStore` change runs `AppContainer.syncAccounts`
synchronously, which rebuilds the runtimes with `ProviderCatalog.make(accounts:vault:http:reusing:)`,
applies the new `WidgetRegistry` to the layout and data store in place (a removed account's in-flight
refresh is cancelled there, so a late response has nothing to commit to), and refreshes any account that
is new. The status item and the panel are never rebuilt on an account change.

## Accounts and sign-in

`ProviderKind` (`Models/Account.swift`) is the enum of providers. It carries each provider's display
name, icon, quick links, and `authMethod` (OAuth or an API key with its key page).

`ProviderLogin` (`Services/ProviderLogin.swift`) is the sign-in contract: `login(prompt:pastedCode:)`
drives a browser or device-code prompt and returns the account's label and credential.
`ProviderLoginCatalog` maps a kind to its login. Browser logins live in
`Services/BrowserProviderLogins.swift` (Claude, Codex, Antigravity) and use `LoopbackCallbackServer`
and `PKCE`; device-code logins and the Cursor and API-key logins live in
`Services/DeviceProviderLogins.swift`. `AddAccountFlow` runs a login for the `AddAccountSheet`.

`CredentialVault` (`Services/AccountCredentialVault.swift`) stores one `AccountCredential` (OAuth
tokens or an API key) per account id in the app's Keychain service.

## Usage

`AccountProviderRuntime` (`Providers/AccountProviderRuntime.swift`) is the one `ProviderRuntime`.
There is one per account. It declares the account's `widgetDescriptors` (the metrics its card can
show, prefixed with the account's `cardID`), loads the credential from the vault, calls the provider's
usage client, maps the response to `MetricLine` values, and returns a `ProviderSnapshot`. Token
refresh, Claude's live plan lookup, and the reset-claim services live in its extensions under
`Providers/<Name>/`. Each provider folder holds a `<Name>UsageClient` (HTTP) and a
`<Name>UsageMapper` (pure response-to-metrics mapping).

`WidgetRegistry.from(providers)` collects every descriptor. `LayoutStore` decides which are placed and
in what order; `WidgetDataStore` turns snapshots into `WidgetData` for the views.

## Refresh loop

`AppContainer.startRefreshing` runs `WidgetDataStore.refreshAll`, then `evaluateNotifications`, then
`TelemetryRecorder.tick`, at launch and then every `RefreshSetting.interval` (5 minutes). Every cadence
and wait is a named constant in `RefreshSetting`. ⌘R runs `refreshAll(force: true)`, which skips the
cache and asks each runtime's hourly reads again (`ProviderRuntime.forgetHourlyReads`); whether a
forced refresh waits out a backoff is `RefreshBackoff.holds`.
`refresh(providerID:)` honours the on-disk `ProviderSnapshotCache`, the account's `RefreshBackoff`,
and a two-minute deadline per account, and reports each real outcome through `onRefreshOutcome`. Each
fetched snapshot is written to the cache as it lands.

## Command line

`OpenUsageCLI` parses its arguments, finds the app bundle it ships inside (`AppBundleLocator`,
`ContainingAppBundle`) to open that app's defaults domain, and hands the rest to `UsageReader` in the
library: the stored accounts (`AccountStore.load`), their descriptors
(`AccountProviderRuntime.widgetDescriptors(for:)`), and the snapshot cache, projected by
`LimitsEnvelope` into the `openusage.limits.v1` JSON that `exportingLimit` declares resource by
resource. The command never refreshes and never opens the Keychain. `CommandLineToolInstaller` is the
Settings-side symlink installer.

## Views

`StatusItemController` (`App/StatusItemController.swift`) owns the `NSStatusItem` and the
`MenuBarPanel`, a key-capable `NSPanel` that hosts `DashboardView`. `StatusItemImageUpdater`
renders the menu-bar strip with `MenuBarStripRenderer`. `PanelHeightController` sizes the panel to
its content.

`DashboardView` switches between the dashboard (`DashboardContentView` → `WidgetGroupedListView` →
`DashboardProviderSection` → `DashboardLiveRow` → `DashboardMetricRow`; the share image and the drag
previews draw the same rows through the static `DashboardAccountRows`), Accounts
(`AccountsView` → `AccountListView` and `AccountDetailView`), and `SettingsScreen`. Right-click
menus are declared as data in `DashboardMenus` and rendered by `ClosureMenuItem`.
`ShareCardRenderer` renders a provider card into the branded PNG behind **Share Screenshot**.

## Updates and telemetry

`UpdaterController` wraps Sparkle. It starts only when the bundle declares `SUFeedURL`, which only
`script/release.sh` writes, so the dev build never checks for updates. See [Updates](updates.md).

`PostHogTelemetrySink`, `TelemetryRecorder`, and `TelemetryStore` send the anonymous daily ping,
crash reports, and the optional provider rollups described in [Privacy](privacy.md). Ids are
kind-scoped (`Account.kindScopedID`), so events name providers, never accounts.

## Logging

`AppLog` writes to unified logging only, subsystem `OpenUsage`, one category per `LogTag`. Every
message passes `LogRedaction` first. See [Debugging](debugging.md).
