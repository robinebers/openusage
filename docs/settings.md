# Settings

Settings lives inside the popover — there is no separate window. Open it with the gear button in the popover footer, ⌘, while the popover is showing, or by right-clicking the menu bar icon and choosing Settings. The dashboard slides over to the Settings screen; the gear becomes a checkmark while you're there. Go back with the checkmark, the ⌘, shortcut, or Esc (Esc always backs out to the dashboard first — pressing it again closes the popover).

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
| Reduce Transparency | on/off | Off keeps the fully translucent Liquid Glass look (cards stay light and glassy). On makes the popover background solid and the cards frosted so they read better over a busy or bright desktop — the glass buttons and controls stay. Turns on automatically if you have macOS's own Reduce Transparency (System Settings → Accessibility → Display) enabled. |

## Usage Display

| Setting | Options | What it does |
|---|---|---|
| Show Usage As | Used / Left | Whether bounded metrics read "48% used" or "52% left" — same toggle as clicking a headline. |
| Reset Times | Countdown / Exact time | "Resets in 3h 25m" vs "Resets today at 6:38 PM" — same toggle as clicking a reset label. |

## Providers

One switch per provider. Turning a provider **off** hides it everywhere (dashboard, Customize, menu bar, the collection endpoint of the [local HTTP API](local-http-api.md)) and pauses its updates. Nothing is deleted — turning it back on restores its metrics and order.

## Advanced

| Setting | Options | What it does |
|---|---|---|
| Log Level | Error / Warning / Info / Debug | How much detail the app writes to its log file. Defaults to Info and persists across launches; raise to Debug while reproducing a problem. Applies immediately. |
| Copy Log Path | button | Copies the log file path (`~/Library/Logs/OpenUsage/OpenUsage.log`) to the clipboard. |
| Reveal in Finder | button | Opens a Finder window with the log file selected. |

See [Logging](logging.md) for the full behavior: subsystem tags, the file size cap, and the guarantee that secrets are never written.

## Version

The app version shows in the popover footer.
