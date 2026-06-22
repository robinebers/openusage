# Menu Bar

Pin your most important metrics straight into the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a quick menu with **Settings** and **Quit**. Left-click opens the popover as usual.

## Pinning

Pin from any row's right-click menu, or from the pin that appears when hovering rows in Customize.

- On first launch the app ships with a default set of pins (Claude Session/Weekly, Codex Session/Weekly, Cursor Auto Limits/API Usage) so the strip shows numbers right away. Change them anytime; Reset in Customize restores this set.
- At most **2 pins per provider**.
- When a pin isn't allowed, the pin button stays clickable — clicking it shakes and shows the reason in the footer (e.g. "Up to 2 pins per provider").
- The Customize footer shows your count: `n pinned`.

## Styles

Settings → Appearance → Menu Style:

- **Text** — provider icon plus values; two pinned metrics from the same provider stack as a labeled pair.
- **Bars** — compact vertical bars, one per pinned metric that has a limit (metrics without limits only appear in Text style).

## What the strip shows

The strip only renders real data. A pinned metric with nothing fetched yet is skipped; a provider whose pins all lack data disappears entirely (icon included). When nothing has data, the strip falls back to the app icon. Pins follow your Customize order.
