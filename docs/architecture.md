# Architecture

OpenUsage is a SwiftPM package with three targets:

- `OpenUsage`: the library, where everything lives.
- `OpenUsageApp`: a thin executable.
- `OpenUsageCLI`: the `openusage` command, shipped at `Contents/Helpers/openusage`.

It uses Swift 6 with strict concurrency, and SwiftUI inside an AppKit status item and panel.

## Composition root

`AppDelegate` (`App/OpenUsageApp.swift`) builds `AppContainer`, starts the refresh loop, creates
`StatusItemController`, and starts Sparkle. It also imports the OpenRouter and Z.ai keys 0.7.x saved
(`Stores/APIKeyV1Files.swift`).

`AppContainer` (`App/AppContainer.swift`) owns the long-lived stores:

| Store | Owns |
|---|---|
| `AccountStore` | Accounts, CLIProxyAPI hubs, and the `CredentialVault`. |
| `CLIProxyHubSync` | The reads that keep each hub's accounts in step with its logins. |
| `LayoutStore` | Provider order, metric order, and undo history. |
| `PopoverState` | The popover's screen and sheets. |
| `WidgetDataStore` | The latest snapshot per account, refresh errors, and display settings. |
| `AccountRenameStore` | Which account name is being edited. |
| `TelemetryRecorder` | The daily ping and optional daily provider account counts. |
| `HideFromScreenShareSetting` | The Hide From Screen Share switch. |

Accounts are the source of truth. Every `AccountStore` change runs `AppContainer.syncAccounts`,
which swaps the runtimes in place and refreshes new ones. The status item and panel are never rebuilt.

## Accounts and sign-in

- `ProviderKind` (`Models/Account.swift`) lists the providers with their names, icons, links, and
  auth methods.
- `ProviderLogin` (`Services/ProviderLogin.swift`) is the sign-in contract. It drives a browser,
  token-page, or device-code prompt and returns a label and a credential. `ProviderLoginCatalog`
  maps each kind to its login.
- Browser logins live in `Services/BrowserProviderLogins.swift`, device-code, Cursor, and API-key logins in
  `Services/DeviceProviderLogins.swift`, and Devin's in `Providers/Devin/DevinLogin.swift`.
- `CredentialVault` (`Services/AccountCredentialVault.swift`) keeps one credential per account in
  the app's Keychain service.

A CLIProxyAPI hub (`Models/CLIProxyHub.swift`) is not a provider. Each supported login on a hub is an
ordinary account of its provider. Its `HTTPClient` is a `HubTunnel`
(`Services/CLIProxyHubClient.swift`), which sends each request through the hub, so the provider's
own code runs unchanged.

## Usage

`AccountProviderRuntime` (`Providers/AccountProviderRuntime.swift`) runs one account. It declares
the account's metrics (`widgetDescriptors`), loads the credential, calls the usage client, maps the
response to `MetricLine` values, and returns a `ProviderSnapshot`.

Each `Providers/<Name>/` folder has a `<Name>UsageClient` for HTTP and a `<Name>UsageMapper` that
maps the response. Token refresh and reset claims live there too, as runtime extensions.

`LayoutStore` keeps which metrics the user hid and their order. `WidgetDataStore` turns snapshots
into data for the views.

## Refresh loop

`AppContainer.startRefreshing` runs at launch and then every 5 minutes (`RefreshSetting.interval`).

- Each pass refreshes accounts, checks quota notifications, and ticks telemetry.
- An account is skipped if its snapshot is less than an interval old or it is in backoff
  (`RefreshBackoff`). Each account has a two-minute deadline.
- Halfway between passes, `refreshHourlyReads` runs reads a provider must not get in the same burst
  as usage, such as Claude's plan and reset grants.
- ⌘R runs `refreshAll(force: true)`, which skips the cache and redoes the hourly reads.

## Command line

`OpenUsageCLI` finds the app bundle it ships inside and hands off to `UsageReader`, which reads
the stored accounts and the snapshot cache. `LimitsEnvelope` writes the `openusage.limits.v2`
JSON. The command never refreshes and never opens the Keychain.

## Views

- `StatusItemController` (`App/StatusItemController.swift`) owns the `NSStatusItem` and the
  `MenuBarPanel` that hosts `DashboardView`.
- `PriorityBoard` (`Models/PriorityBoard.swift`) ranks accounts for both the Priority tab and the
  menu bar, so the two always agree.
- `DashboardView` switches between the dashboard (`DashboardContentView`), Accounts
  (`AccountsView`, `AccountListView`, `AccountDetailView`, `HubDetailView`), and
  `SettingsScreen`.

## Updates, telemetry, and logging

- `UpdaterController` wraps Sparkle. Only `script/release.sh` writes `SUFeedURL`, so dev builds never
  check for updates. See [Updates](updates.md).
- `PostHogTelemetrySink` sends the anonymous daily ping, crash reports, and optional daily account
  counts by provider. Events name providers, never accounts. See [Privacy](privacy.md).
- `AppLog` writes to unified logging (subsystem `OpenUsage`). It drops lines below the level set in
  Settings and redacts every message with `LogRedaction`. See [Debugging](debugging.md).
