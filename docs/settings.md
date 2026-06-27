# Settings

Settings lives inside the popover — there is no separate window. Open it from the footer's **Settings** button, with ⌘, while the popover is showing, or by right-clicking the menu bar icon and choosing Settings. The dashboard slides over to the Settings screen, which carries a back button in its top-left corner. Go back with that button, the ⌘, shortcut, or Esc (Esc always backs out to the dashboard first — pressing it again closes the popover).

## Startup

| Setting | Options | What it does |
|---|---|---|
| Launch at Login | on/off | Registers the app as a login item (the system's login-item registry is the source of truth). |
| Global Shortcut | record a shortcut | Global shortcut that toggles the popover from anywhere. Click the field and press a combo; the ⓧ clears it and disables the shortcut. |

## Appearance

| Setting | Options | What it does |
|---|---|---|
| Menu Style | Text / Bars | How pinned metrics render in the menu bar. See [Menu bar](menu-bar.md). |
| Theme | System / Light / Dark | App-wide appearance override for the popover. |
| Density | Default / Compact | Default breathes; Compact is a real information-dense mode — text steps down one size, rows and provider sections pull together, and Customize / Settings rows tighten with them. In both, consecutive one-line metrics (Today / Yesterday / …) pull together; Compact pulls harder. |
| Time Format | Auto / 12-hour / 24-hour | How exact times read (e.g. "Resets today at 6:38 PM" vs "18:38"). Auto follows the system. |

## Usage Display

| Setting | Options | What it does |
|---|---|---|
| Show Usage As | Used / Left | Whether bounded metrics read "48% used" or "52% left" — same toggle as clicking a headline. |
| Reset Times | Countdown / Exact time | "Resets in 3h 25m" vs "Resets today at 6:38 PM" — same toggle as clicking a reset label. |
| Always Show Pacing | Off / On | Off (default) shows pacing only when a metric is close to or over its limit. On surfaces it on every metric with a reset window: on-track rows gain their projection ("~33% left at reset") and an even-pace tick marking where steady use would put you right now. Metrics without a reset window have no pace to show. |

## Providers

One switch per provider. Turning a provider **off** hides it everywhere (dashboard, Customize, menu bar, the collection endpoint of the [local HTTP API](local-http-api.md)) and pauses its updates. Nothing is deleted — turning it back on restores its metrics and order.

## Privacy

| Setting | Options | What it does |
|---|---|---|
| Share Anonymous Usage | On / Off | On (default) shares anonymous, daily usage summaries — no account details, credentials, or usage values. Off stops all sharing immediately. See [Privacy & Usage Data](privacy.md) for exactly what is and isn't sent. |

## Advanced

| Setting | Options | What it does |
|---|---|---|
| Log Level | Error / Warning / Info / Debug | How much detail the app writes to its log file. Defaults to Info and persists across launches; raise to Debug while reproducing a problem. Applies immediately. |
| Copy Log Path | button | Copies the log file path (`~/Library/Logs/OpenUsage/OpenUsage.log`) to the clipboard. |
| Reveal in Finder | button | Opens a Finder window with the log file selected. |

See [Logging](logging.md) for the full behavior: subsystem tags, the file size cap, and the guarantee that secrets are never written.

## Version

The app version shows in the popover footer.

Your settings carry across updates — layout, pins, preferences, and the menu-bar shortcut all stay put. When an update changes how a setting is stored, the app upgrades it in place on launch, stepping through any in-between versions if you skipped a few. Nothing is reset. (Earlier betas wiped all settings on every update; that no longer happens.)
