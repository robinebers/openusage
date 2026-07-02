# Settings

Settings lives inside the popover — there is no separate window. Open it from the footer's **⌄** menu next to the Customize button, with ⌘, while the popover is showing, or by right-clicking the menu bar icon and choosing Settings. The dashboard slides over to the Settings screen, which carries a back button in its top-left corner. Go back with that button, the ⌘, shortcut, or Esc (Esc always backs out to the dashboard first — pressing it again closes the popover).

## Startup

| Setting | Options | What it does |
|---|---|---|
| Launch at Login | on/off | Registers the app as a login item (the system's login-item registry is the source of truth). |
| Global Shortcut | record a shortcut | Global shortcut that toggles the popover from anywhere. Click the field and press a combo; the ⓧ clears it and disables the shortcut. |

## Appearance

| Setting | Options | What it does |
|---|---|---|
| Menu Style | Text / Bars | How starred metrics render in the menu bar. See [Menu bar](menu-bar.md). |
| Theme | System / Light / Dark | App-wide appearance override for the popover. |
| Density | Default / Compact | Default breathes; Compact is a real information-dense mode — text steps down one size, rows and provider sections pull together, and Customize / Settings rows tighten with them. In both, consecutive one-line metrics (Today / Yesterday / …) pull together; Compact pulls harder. |
| Time Format | Auto / 12-hour / 24-hour | How exact times read (e.g. "Resets today at 6:38 PM" vs "18:38"). Auto follows the system. |
| Increase Transparency | Off / On | Off (default) keeps the popover a solid panel. On makes it translucent so your desktop shows through, while keeping the numbers legible. It pauses automatically when you have the macOS **Reduce Transparency** or **Increase Contrast** accessibility setting turned on (a note explains why), so it never works against those preferences. |

## Usage Display

| Setting | Options | What it does |
|---|---|---|
| Show Usage As | Used / Left | Whether bounded metrics read "48% used" or "52% left" — same toggle as clicking a headline. |
| Reset Times | Countdown / Exact time | "Resets in 3h 25m" vs "Resets today at 6:38 PM" — same toggle as clicking a reset label. |
| Always Show Pacing | Off / On | Off (default) shows pacing only when a metric is close to or over its limit. On surfaces it on every metric with a reset window: on-track rows gain their projection ("~33% left at reset") and an even-pace tick marking where steady use would put you right now. Metrics without a reset window have no pace to show. |

## Notifications

OpenUsage can alert you with a macOS notification when a metric's pace gets worse, so you don't have to keep the popover open to catch a quota creeping toward its limit. Alerts work while the app runs in the menu bar, even with the popover closed.

| Setting | Options | What it does |
|---|---|---|
| Almost Out | On / Off | Alerts the first time a metric drops under 10% remaining for the period. |
| Cutting It Close | On / Off | Alerts when a metric is projected to finish the period with little left — close to its limit. |
| Will Run Out | On / Off | Alerts when a metric is projected to run out before it resets. |

Each alert fires **once per metric per reset period**, so you get a heads-up without repeats on every refresh. Alerts fire only when a quota *worsens* while OpenUsage is running — a quota that's already in a bad state when you launch won't alert until it recovers and worsens again, or a new period begins. If a metric recovers (its pace eases back) and later worsens again, it can alert again. When a new period begins, the slate is wiped clean. Metrics without a reset window, or while their data can't be read, don't pace and never alert. Turn all three off to silence everything. When several alerts fire at once, they stack into a single grouped banner.

All three alerts default off. The first time you turn one on, OpenUsage asks for notification permission; if you decline (or turn notifications off for OpenUsage in System Settings later), a warning mark appears on the Notifications header and an "Open System Settings" button shows under the toggles so you can re-enable them. A notification's title is the alert name, its subtitle names the provider and metric, and its body is the plain-language verdict.

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

Your settings carry across updates — layout, stars, preferences, and the menu-bar shortcut all stay put. When an update changes how a setting is stored, the app upgrades it in place on launch, stepping through any in-between versions if you skipped a few. Nothing is reset. (Earlier betas wiped all settings on every update; that no longer happens.)
