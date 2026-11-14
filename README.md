# OpenUsage × Expo Exact — rewrite experiment

This branch is a **draft experiment**: a complete rewrite of OpenUsage 0.8.0 on
[Expo Exact](https://github.com/expo/exact) instead of SwiftUI/AppKit. Nothing
here is meant to merge; it exists to answer "what is Exact, and can it actually
build a macOS menu-bar app?"

## What Exact is

Exact is Expo's next-generation app runtime (public since Nov 2026, pre-1.0,
no API stability). You write UI once in **Contract**, a declarative language
(`app.contract`), and data logic in TypeScript (`app.ts`). There is no webview
and no JS bridge: the same source runs as

- **web** — a ~20 KB runtime + one ES module on the real DOM,
- **macOS** — a Rust kernel driving real AppKit views through a Swift host
  (`ExactKit`), laid out by Taffy,
- **iOS** — the same idea on UIKit (skipped here: needs iOS Sim SDK 27.1, this
  machine has 26.5),
- **Linux/Windows** — a painted host (vello), in progress.

It's agent-native: `scripts/agent.mjs` drives any running app (tree, tap, type,
screenshot, fake clock), and `app.test.contract` tests run unchanged on every
host. `bun exact.mjs verify web` also audits contrast, hit-target sizes and
largest-text-size layout.

## What it can already do (verified by building this)

- A **menu-bar accessory app**: `host.macos.activationPolicy: "accessory"` gives
  no Dock tile and no window at launch, and a `button -exact-menu="status"` in
  the page becomes a real `NSStatusItem` — click runs `focus()` to show the
  window. `window.keepRunning` hides rather than closes.
- The dashboard's Priority / All Usage panel: sections, ring progress drawn as
  SVG, provider icons, tinted amounts, segmented control, right-click menus
  (`contextPopover` + `contextmenu`), popover menus, grouped-list settings,
  routing with push/back, `state ... persist`.
- Provider icons as plain `.svg` assets; system symbols via `image "symbol:x"`.
- A ticking clock via `task every(30000, …)` + `performanceNow()`.

## What it can't do yet (for this use case)

- **No anchored popover panel.** Exact shows a normal `NSWindow` (380×560 here);
  OpenUsage's `NSPanel` anchored to the status item can't be written today.
- **No programmatic quit for accessory apps.** The only Quit is the host's
  `status-quit` inside a status-item *menu* — and a status item with a menu
  opens the menu on click instead of running `press`. So this app's click
  opens the window, and "Quit OpenUsage" is `hideWindow()` (the process stays
  alive — honest gap).
- **No real provider wiring attempted.** Exact has Keychain (`storage.keychain`),
  granted `net.fetch` and an OAuth fixture — a real port would sign in per
  provider; this experiment ships seeded data matching the screenshots.
- **Windows tray icon accepted but unbuilt**; menu is a plain `NSMenu`, not a
  custom SwiftUI menu like OpenUsage's header menu.

## Layout

- `openusage-exact/` — the app (Contract + TypeScript + tests + provider icons)
- `exact/` — the SDK as a git submodule @ `0104e402`

## Run it

```sh
git submodule update --init
cd openusage-exact
bun scripts/exact.mjs setup     # one-time: toolchains, Hermes, Chromium
bun exact.mjs web               # the panel in a browser
bun exact.mjs mac --run         # the menu-bar app on macOS
bun exact.mjs test web          # the tests
bun exact.mjs verify web        # screenshots + a11y findings
```

## Deliberate simplifications vs 0.8.0

- Priority sections are Pinned / Running Out / Used Up (Lose It, Attention and
  Burning-Fast grouping are stubbed; the settings toggles exist but are inert).
- No account reordering, hiding *accounts*, usage-details popover depth,
  notifications, Sparkle, or real refresh — "Refresh" marks accounts refreshing
  for 1.5 s, then clears.
- Settings persist via `state persist`, not UserDefaults.
