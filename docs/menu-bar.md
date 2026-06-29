# Menu Bar

Star your most important metrics straight into the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a quick menu with **Settings** and **Quit**. Left-click opens the popover as usual.

## Starring

Star a metric from any row's right-click menu, or from the star that appears when hovering rows in Customize.

- On first launch the app ships with a default set of stars (Claude Session/Weekly, Codex Session/Weekly, Cursor Auto Usage/API Usage) so the strip shows numbers right away. Change them anytime; Reset in Customize restores this set.
- At most **2 stars per provider**.
- When a star isn't allowed, the star button stays clickable — clicking it shakes and shows the reason in the footer (e.g. "Up to 2 stars per provider").
- The Customize footer shows your count: `n starred`.

## Styles

Settings → Appearance → Menu Style:

- **Text** — provider icon plus values; two starred metrics from the same provider stack as a labeled pair.
- **Bars** — compact vertical bars, one per starred metric that has a limit (metrics without limits only appear in Text style).

## What the strip shows

The strip only renders real data. A starred metric with nothing fetched yet is skipped; a provider whose stars all lack data disappears entirely (icon included). When nothing has data, the strip falls back to the app icon. Stars follow your Customize order — Always Visible metrics first, then On Demand ones. A metric can be starred whether it's Always Visible or On Demand.
