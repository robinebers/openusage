# Menu Bar and Side Notch

Star your most important metrics into either the menu bar or an optional side notch.

## Choosing a surface

Settings → Appearance → **Display Mode**:

- **Menu Bar** (default) keeps the established status item. Left-click opens the dashboard; right-click opens Settings or quits.
- **Side Notch** replaces the status item with a small handle on the right edge of the main display. Hover the handle to reveal the starred providers; the notch grows to fit the number of subscriptions, then scrolls when it reaches the available panel height. Hover a provider for its account recap, and click a provider to open the full dashboard beside the notch. Right-click the notch for Settings or Quit.

The Side Notch always expresses its rings as **Used**, even if the dashboard and menu bar are set to Left. Each provider recap puts its shortest limit first: session when available, followed by weekly or monthly for the subscription. That first limit also drives the provider ring. A known reset appears beside each limit. When an account has an available rate-limit reset with known expiry data, the recap also shows its available count and the soonest expiration date. Ring colors are green normally, yellow when the current pace projects that the account will reach or cross its limit before reset, and red once at least 90% is used.

The global shortcut and links from notifications or desktop widgets open the same dashboard in both modes. Switching modes never changes which metrics are starred.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a quick menu with **Settings** and **Quit**. Left-click opens the popover as usual.

## Starring

Star a metric from any row's right-click menu, or from the always-visible star beside a metric in Customize.

- On first launch the app ships with a default set of stars (Antigravity Session/Weekly, Claude Session/Weekly, Codex Weekly, Cursor Models/Other Models, Copilot Credits, OpenRouter Credits, Z.ai Session/Weekly) so the strip shows numbers right away. Change them anytime; a provider's Reset restores its defaults, and Reset All restores the full set. Only providers that are turned on render in the strip — and a fresh install starts with just the providers detected on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)) — so the default stars don't crowd the menu bar with tools you don't use.
- Account cards from the same provider star independently: you can show Weekly for one Codex account and Session for another. When each of several accounts has exactly one star, their values stack under one provider icon — even when the starred metrics differ (Weekly for one account, Session for another) — in the same top-to-bottom order as their cards; dragging the cards immediately updates the stack order.
- At most **2 stars per provider card** — each account card has its own two slots.
- When a star isn't allowed, the star button stays clickable — clicking it shakes and shows the reason in a temporary pill over the bottom of Customize (for example, "Up to 2 stars per provider").

## Styles

With Display Mode set to Menu Bar, Settings → Appearance → Icon Style:

- **Text** — provider icon plus values; two starred metrics from the same provider stack as a labeled pair.
- **Bars** — a compact glyph containing the first four starred metrics that have a limit (metrics without limits only appear in Text style).

## Hiding usage while screen sharing

Settings → Privacy → **Hide From Screen Share** (off by default). While your screen is being shared or recorded — a Zoom/Meet/Teams share, a screen recording, macOS Screen Sharing — the menu bar is replaced with the OpenUsage icon and wordmark, or the side notch hides its readings. The moment the capture ends, your starred metrics come right back. Captures you start yourself (a screen recording, for example) count too.

Detection rides the system's own "an app is capturing the screen" signal — the same one that lights the capture indicator in the menu bar — checked the instant it changes and re-checked every few seconds while the setting is on.

Normally:

![The menu bar strip showing usage values](assets/menu-bar-privacy-idle.png)

While the screen is shared or recorded:

![The menu bar strip concealed behind the OpenUsage wordmark](assets/menu-bar-privacy-sharing.png)

## What the strip shows

The strip only renders real data. A starred metric with nothing fetched yet is skipped; a provider whose stars all lack data disappears entirely (icon included). When nothing has data, the strip falls back to the app icon. Stars follow your Customize order — Always Visible metrics first, then On Demand ones. A metric can be starred whether it's Always Visible or On Demand.
