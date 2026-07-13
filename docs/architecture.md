# Architecture

A high-level map of how OpenUsage is put together, for people working on the code. For what the app
*does*, start with the [behavior docs](README.md).

## The shape of the app

OpenUsage is a SwiftPM package with a shared module and two thin executables — there is no Xcode project.
The main executable is a menu-bar app: a SwiftUI interface hosted inside an AppKit status item and panel.
The code is grouped by role:

- `App/` — startup and the AppKit bridge (status item, panel, the app entry point).
- `Models/` — the small value types the rest of the app speaks in (`MetricLine`, `WidgetData`, descriptors).
- `Providers/` — one folder per provider (Claude, Codex, Cursor, Devin, Grok, OpenCode, …).
- `Stores/` — the mutable state the UI observes.
- `Services/` — shared infrastructure (HTTP, the local API, process running).
- `Support/` — small shared helpers (formatting, parsing, animations).
- `Views/` — the SwiftUI screens (dashboard, customize, settings, menu-bar strip).

## Composition root

`AppContainer` is the one place that wires everything together. At launch it builds the list of
providers, turns it into a `WidgetRegistry`, creates the stores, starts the periodic refresh loop, and
starts the local HTTP API. Everything else receives what it needs from here rather than reaching for
globals, which keeps the pieces testable in isolation.

The `openusage` executable imports the same module. A normal invocation reads `ProviderSnapshotCache`
and exits; `--force` constructs the canonical `ProviderCatalog` and calls `WidgetDataStore`'s forced
refresh path before reading. Providers annotate the scalar resources they export through the stable
limits contract; the CLI and `/v1/limits` share one serializer over those same normalized snapshots.
It never launches the GUI or duplicates provider, auth, pricing, or mapping logic.

## The provider pipeline

Each provider is a small module that conforms to `ProviderRuntime`. A refresh flows through three parts:

1. **Auth store** — reads credentials that already exist on the machine (config files, keychain). OpenUsage
   never asks the user to paste tokens.
2. **Usage client** — makes the HTTP calls to the provider's API.
3. **Mapper** — turns the provider's response into the app's own vocabulary: a `ProviderSnapshot`
   containing typed widget values (`.progress`, `.values`, `.badge`, `.chart`) plus `.text` notices that
   remain available through the local API but do not render as widgets.

Because every provider produces the same normalized `MetricLine` shapes, the UI renders them all the same
way and doesn't need to know provider-specific details. To add one, see
[Adding a provider](adding-a-provider.md).

## Stores

The UI reads from a few observable stores:

- `WidgetDataStore` — the latest snapshot per provider, plus refresh and caching. It keeps machine-local
  cached snapshots separate from rendered snapshots so peer history can never be written back out and
  counted again.
- `LayoutStore` — which metrics are shown, the provider/metric order, and which metrics are starred for the
  menu bar.
- `ProviderEnablementStore` — which providers the user has turned on or off.
- `ICloudUsageSyncStore` — one coordinated, atomic history file per Mac, iCloud metadata notifications,
  and the visible device/error state. File access is injected for lifecycle and failure tests.

Refresh runs on a timer in `AppContainer`; each pass respects the cache, so the network is only hit once a
snapshot has actually expired.

Providers with spend tiles carry an explicit history scope beside their export descriptors. Machine-local
sources can be summed across device files; account-wide sources such as Cursor cannot. `WidgetDataStore`
re-renders only the spend rows from the union, leaving quota and error state local.

## The AppKit bridge

macOS menu-bar apps live in an `NSStatusItem`. OpenUsage shows its content in a custom, key-capable
`NSPanel` rather than an `NSPopover`: a popover's window is only key while the whole app is active, and
activating a menu-bar (accessory) app is asynchronous and unreliable on recent macOS, so a popover
ends up unable to receive keystrokes until a second click. A non-activating `NSPanel` whose
`canBecomeKey` is `true` takes key focus the instant it opens, so keyboard navigation and the Settings
shortcut recorder just work. `App/` owns that AppKit layer and hosts the SwiftUI views inside it, so
the bulk of the UI can stay plain SwiftUI.

## Platform support

OpenUsage runs on macOS 15 (Sequoia) and later. It is built against the latest SDK and back-deploys:
on macOS 26 (Tahoe) it uses the system's Liquid Glass controls, and on macOS 15 it falls back to the
standard controls with the same behavior (the footer still pins, the buttons keep their states). Every
one of those version checks lives in a single file — `Support/LiquidGlassFallbacks.swift` — so the views
stay free of `#available` checks.

The release build (`script/release.sh`) ships a universal binary (arm64 + x86_64), so a single DMG runs
natively on both Apple Silicon and Intel Macs. The dev build (`script/build_and_run.sh`) stays host-arch
only — a universal dev build just doubles compile time on the maintainer's own machine for no benefit.

## Local HTTP API

A small loopback server exposes the current usage as JSON on `127.0.0.1:6736` for other local tools. See
[Local HTTP API](local-http-api.md) for the endpoints and the privacy tradeoff.
