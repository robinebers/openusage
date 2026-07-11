# Model-Hover Panel — Native Design Direction

> **Historical / superseded.** This design report guided the model-breakdown hover panel that shipped
> on 2026-07-04. See [Dashboard rows](../../dashboard.md#rows),
> [`HoverPopoverState.swift`](../../../Sources/OpenUsage/Views/HoverPopoverState.swift), and
> [`ModelUsageDetail.swift`](../../../Sources/OpenUsage/Views/ModelUsageDetail.swift) for current
> behavior and implementation. References, line numbers, and proposed component names below remain
> unchanged as a record of the design decision at that time.

**Research report — 2026-07-04**
**Question:** What should the hover panel for the Today / Yesterday / Last 30 Days spend rows look like, given the attached AI-generated concept (a "Models" flyout with a "TOP DRIVER" hero card, donut, and ranked model list)? The owner's verdict on the concept: directionally right, but "a bit over the top" — inconsistent type sizes, not native enough. Goal: an Apple-first, native macOS treatment that belongs in OpenUsage, works for Cursor / Claude / Codex / Grok, and is not Cursor-branded.

---

## Executive Summary

Keep the concept's *information* (ranked model list, top-driver emphasis, per-model proportional bars, period label in the header) and drop its *theatricality* (the "TOP DRIVER" pill, the oversized donut, the card-in-card nesting, the mixed type ramp, the per-model provider logos). Apple's native pattern for "break a total down by contributor" — Activity Monitor's Energy tab, Screen Time's per-app list, the Battery menu extra's per-app usage, System Settings ▸ Storage — is a **flat, compact ranked list with proportional horizontal bars and one quiet summary line**, never a hero card with a ring chart.

Recommended direction: **a small SwiftUI `.popover` anchored to the hovered spend row** (the exact pattern the app already uses for `UsageSparkline` → `UsageTrendDetail`), containing a single flat list of models ranked by spend, each row a label + monospaced dollar figure + a thin proportional `Capsule` bar, plus one quiet header that names the period and the top model. No donut, no hero card, no per-model icons, no new dependency. Top-driver emphasis comes from **rank order + a single semibold "Top" tag** on the leading row, the way Screen Time marks the heaviest app, not from a shouted pill.

---

## 1. The app's existing design language (concrete catalog)

Read from `Sources/OpenUsage/Views/` + `Sources/OpenUsage/Stores/DensitySetting.swift` + `Sources/OpenUsage/Support/Theme.swift` + `Sources/OpenUsage/Support/LiquidGlassFallbacks.swift`. The new panel must match this.

### 1.1 Typography ramp (explicit point sizes, not semantic styles)

The app **does not** use semantic `.headline` / `.subheadline` / `.caption` for its data rows. It resolves explicit point sizes through `DensitySetting` because "semantic `.headline.weight(.regular)` does not match `.headline` on macOS" (`WidgetRowView.swift:33-36`). Every size steps down one point in Compact.

| Role | Regular | Compact | Weight | Foreground |
|---|---|---|---|---|
| Provider section header (name) | 14 | 13 | `.semibold` | `.primary` |
| Metric row label | ~13 (`NSFont.headline` base) | base − 1 | `.semibold` | `.primary` |
| Supporting / detail / under-bar | 12 | 11 | `.regular` | `.primary` for the value, `.secondary` for context |
| Plan badge, stale tag | 11 | 10 | `.regular` | `.secondary` / `.tertiary` |
| Nav bar title (Customize/Settings) | — | — | `.headline` (semantic) | — |
| Footer identity ("OpenUsage 0.7.x", "Next update in 3m") | — | — | `.caption2` (semantic) | `.secondary` |
| UsageTrendDetail header title | 13 | — | `.semibold` | `.primary` |
| UsageTrendDetail readout / axis / note | 11 / 10 | — | `.regular` | `.secondary`, `.monospacedDigit()` |
| Tooltip bubble | 12 | — | `.regular` | `.primary` |
| "Copied to clipboard" pill | 12 | — | `.semibold` | `Theme.positive` |

**Rules the panel must follow:**

- The value (the number the user opened the popover to read) is `.primary`; everything around it (period label, source note, "Top" tag) is `.secondary`. `.tertiary` is reserved for inactive content on glass (`ProviderSectionHeader.swift:73-80`).
- Numbers use `.monospacedDigit()` and `.contentTransition(.numericText())` so live-updating figures don't jitter (`DashboardView.swift:701-709`, `WidgetRowView.swift:226`).
- The label and the value on a single-line row share the **same point size**; weight alone carries the hierarchy ("semibold alone keeps the name/value hierarchy", `WidgetRowView.swift:308-310`). The concept screenshot violates this — its dollar amounts read as a different size/weight than the model names.

### 1.2 Layout dimensions (4pt grid)

- **Popover width: 320pt fixed** (`DashboardView.swift:64`). The task brief's "~360pt" is a touch wider than the real panel; the hover panel should sit *at or under* 320 to feel like the same family. The existing `UsageTrendDetail` is 240pt and reads as a comfortable detail popover.
- Outer padding: 14pt horizontal. Row horizontal padding: 14pt. Card gutter: 5pt (3pt Compact).
- Section spacing: 14pt (8pt Compact). Header→card: 4pt (2pt Compact).
- Text-row vertical padding: 6pt (4pt Compact); consecutive text rows condense to 2pt (1pt Compact) so Today / Yesterday / Last 30 Days read as **one cluster, not evenly-spaced full-height rows** (`WidgetRowView.swift:60-77`). This condensing rule is the single most relevant precedent for the ranked list — the hover rows should behave the same way.
- Card corner radius: 12pt, `.continuous` (`Theme.swift:60`). The hover panel itself is a system `.popover`, so its outer corner is system-drawn; any in-panel cards (if we keep any) use 12pt.
- Meter capsule height: 5pt (4pt Compact) — a deliberate thin hairline, not a chunky slab ("a 10pt bar read as a chunky slab next to them", `DensitySetting.swift:52-54`).
- Sparkline height: 18pt (14pt Compact). Trend detail chart height: 76pt at width 240pt.

### 1.3 Materials & color

- **Page surface:** `Theme.traySurface` = `NSColor.textBackgroundColor` — opaque, white in light / near-black in dark, no desktop-tint. The popover reads as one solid panel.
- **Grouped cards:** `Theme.cardShape` (RoundedRect r=12) filled `traySurface` + overlaid `.fill.quaternary` — the macOS System Settings grouped-box look, **borderless** (no stroke on live cards). A hairline `.separator` stroke appears only on lifted single-row chips (`Theme.swift:83-86`).
- **Liquid Glass is reserved for chrome** — the footer/top bar (`barGlass()`) and controls (`glassButtonStyle`, `interactiveGlass`) — never the data cards. `Theme.swift:7-9` and the `liquid-glass` skill are explicit: "keep Liquid Glass out of the content layer and back content with standard materials instead." The concept's translucent card-in-card over a dark gradient is the opposite of this rule.
- **Meter / bar fills are system palette, full strength:** blue = `systemBlue`, yellow = `systemYellow`, red = `systemRed` (`Theme.swift:25-31`). No provider-brand gradients. The trend sparkline uses the same blue as a healthy meter (`Theme.meterFill(.normal)`). A proportional "share" bar in the hover panel should use this blue too — it's the established "this is a usage quantity" color.
- Notice = system orange, positive = system green.

### 1.4 The existing hover-detail precedent (the pattern to copy)

`UsageSparkline` → `UsageTrendDetail` (`UsageSparkline.swift:38-47`, `UsageTrendDetail.swift`) is the app's only existing "hover a row, get a richer breakdown" flow, and it is the right skeleton for the model panel:

- Anchored with SwiftUI `.popover(isPresented:)` and `arrowEdge: .top`, anchored to the **bar strip**, not the whole row, so the arrow points at the chart.
- Driven by `TrendHoverState` (`@Observable`): **400ms reveal dwell**, **180ms grace** to let the cursor travel from the inline row into the popover without it closing; `dismissAll()` is called from the popover's close path so it can't orphan (`DashboardView.swift:255-258`).
- Width 240pt, internal padding 12pt, header is title-left + monospaced readout-right, then the chart, then an axis row, then an optional 10pt source note. No card-in-card; it's one flat padded `VStack`.
- Hovering a bar dims the others to 0.35 opacity — the "selection reads without a second color" trick. The model panel can reuse this for the hovered row.

The model panel should be **the same component shape**, just with a ranked list in place of the bar chart.

### 1.5 Hover tooltips (the lighter precedent, and why it's not enough here)

`.hoverTooltip(_)` (`HoverTooltip.swift`) draws a one-line text bubble in a separate click-through `NonKeyPanel` one level above the popover. It exists because SwiftUI overlays are clipped to the popover window and a tooltip must float free. But it is **text-only** — it cannot host a ranked list with bars. The model breakdown needs the `.popover` path, not the tooltip path. (The tooltip remains the right tool for the existing "hover the value for exact figures" affordance on the spend rows, and the panel can layer on top of it.)

---

## 2. Critique of the attached concept screenshot

### 2.1 Keep

- **Ranked model list.** This is exactly how Apple breaks a total down by contributor (Screen Time, Storage, Activity Monitor Energy). Rank is the clearest signal.
- **Per-model proportional bar.** A thin proportional bar per row is the native idiom — Screen Time's per-app list and Storage's per-category list both do this. It's already in the app's visual vocabulary as the meter capsule.
- **Period label in the header** ("Last 30 Days"). The data scopes to the hovered row, so the panel must say which period. Quiet, trailing, `.secondary` — the concept has it right in placement, wrong in weight (it's competing with the title).
- **Top-driver emphasis.** The user genuinely wants to know "which model dominated this period." Emphasis is correct; the *form* of the emphasis (a pill + donut + hero card) is what's over the top.
- **A footer source line** ("From your Cursor usage history"). The app already does this in `UsageTrendDetail` (`note`, 10pt `.secondary`). Good — but it must be **provider-neutral** ("From your usage history" / "From <provider> logs"), not Cursor-branded, since the panel serves Claude / Codex / Grok too.

### 2.2 Drop or tone down

- **The "TOP DRIVER" pill.** All-caps badge in a brand-blue pill is marketing language, not macOS UI. Apple marks the heaviest contributor with **rank position + a quiet word** ("Most used", Screen Time) or just by **putting it first** with no label at all (Storage, Activity Monitor). Drop the pill.
- **The oversized 58% donut.** Three problems: (1) a donut duplicates the per-row bars — both encode "share of total," so the user reads the same fact twice; (2) the 58% is already shown as "58% of all model spend" in text, so it's *tripled*; (3) a ring chart for a 5-row breakdown is the wrong chart form — rings are for *parts of a whole shown at a glance*, and a ranked list already does that better. Screen Time, Storage, and Battery all skip the ring for this exact case. Drop the donut.
- **The hero card-in-card.** A gradient-filled blue card nested inside the popover card is heavy visual hierarchy that fights the app's flat, borderless grouped-card language. The app's cards are `.fill.quaternary` on `traySurface` with no stroke — the concept's dark-blue gradient card is from a different design system entirely. Drop the hero card; let the top row live in the same list as the others, marked only by rank + a quiet "Top" tag.
- **Inconsistent type sizes.** The concept mixes a very large 58%, a small TOP DRIVER label, medium model names, and dollar amounts in yet another weight. The app's rule is one point size per role, weight-only hierarchy. The panel should use **two sizes max**: the row size (= `supportingPointSize`, 12/11) and the header size (= `headerPointSize`, 14/13).
- **Per-model provider logos.** The concept draws the OpenAI logo for GPT, the Anthropic mark for Claude, a Bugbot robot, etc. The app **does not ship per-model brand assets** — it ships one `ProviderIcon` per *provider*, used once in the section header. Adding per-model logos is brand-load, scope creep, and a licensing/maintenance burden. Apple's native fallback for "icon per item in a breakdown" is **no icon** (Screen Time uses app icons because they're installed apps; Storage uses category glyphs; Activity Monitor uses no icons in its per-process list). For models, a **neutral leading monogram** (first letter in a small secondary-tinted circle) or **no icon at all** is the native choice. Recommendation: no icon at first; a monogram is a cheap later enhancement.
- **The right-chevron on every row.** The concept makes every row look tappable into a model detail. If there's no per-model detail screen behind it (there isn't, in scope), the chevron is a lie. Drop it, or add it only to the top model if a detail is planned.
- **"Models" as the title.** The panel is scoped to one provider's spend for one period; the title should carry the **period** ("Last 30 Days" / "Today" / "Yesterday"), not the generic word "Models". The provider's name is already in the section header the user hovered from; repeating it is redundant, but the *period* is the variable the hover changes and is what the user needs to see confirmed.

### 2.3 How Apple would do it

Look at the four native references:

- **Activity Monitor ▸ Energy ▸ "12 hr Power" list** — flat ranked list of processes, no icons, no bars even; just a percentage per row. The lightest possible treatment.
- **Screen Time ▸ See All App & Website Activity** — ranked list with app icon, name, duration, and a thin proportional bar. The bar is full-width, low-contrast, no card around each row. The top app is just first in the list.
- **Battery menu extra ▸ "Apps Using Significant Energy**" — flat list, no bars, no icons, just app name + "%". Compact, scannable, dismissable.
- **System Settings ▸ Storage** — categories ranked by size, each with a small glyph + name + size + thin proportional bar. One quiet summary at the top ("System Data — 42.3 GB of 512 GB").

The common shape is: **header line with the total + period, then a flat ranked list, each row = name + number + optional thin proportional bar, no hero card, no donut, no all-caps badge.** That is the target.

---

## 3. Three concrete native directions

All three anchor to the hovered spend row with the existing `.popover(arrowEdge: .top)` + `TrendHoverState`-style hover coordinator (400ms reveal, 180ms grace, `dismissAll()` on popover close). They differ in how the breakdown is drawn inside.

### Direction A — Flat ranked list (Screen Time style) **[recommended]**

```
┌──────────────────────────────────────┐
│ Last 30 Days              $8.8K · 9B │  ← header: period left, total right (headerPointSize / supportingPointSize, .primary / .secondary)
│ Top model Claude 4.8 Opus    $5.1K  │  ← first row, "Top model" quiet tag, semibold name
│ ─────────────────────────────────── │  ← .separator opacity, full width
│   Claude 4.8 Opus   2.9B    $5.1K ▓▓▓▓▓▓▓▓░░ 58%
│   GPT-5.5           827M    $1.7K ▓▓▓░░░░░░░ 19%
│   Claude Fable 5    412M    $661  ▓░░░░░░░░░  7%
│   Claude 4.7 Opus   294M    $470  ▓░░░░░░░░░  5%
│   Other             181M    $290  ░░░░░░░░░░  3%
│ From your usage history (estimated) │  ← 10pt .secondary source note
└──────────────────────────────────────┘
```

**Structure:**

- One `VStack(alignment: .leading, spacing: 8)`, padding 12, width **280pt** (between the 240pt trend popover and the 320pt main popover; wide enough for the bar + figures, narrow enough to feel like a detail).
- **Header row:** `HStack(firstTextBaseline)`. Left: period name ("Today" / "Yesterday" / "Last 30 Days") at `headerPointSize` (14/13), `.semibold`, `.primary`. Right: the period total ("$8.8K · 9B tokens") at `supportingPointSize` (12/11), `.monospacedDigit`, `.secondary`. This is the `UsageTrendDetail.header` pattern verbatim, just with the period name swapped in for the chart title.
- **Top-model summary line** (one line, not a card): "Top model Claude 4.8 Opus · $5.1K (58%)" at `supportingPointSize`, `.secondary`, with the model name and the percentage in `.primary` for emphasis. This is the Screen Time "Most used" idiom — one quiet line, no pill, no donut. Optional; drop it if the list is ≤3 rows (then rank alone is enough).
- **Separator:** `Divider().opacity(0.5)` or a 0.5pt `.separator` stroke, full width.
- **Ranked list:** a `VStack(spacing: 0)` of rows, each row:

  ```swift
  HStack(alignment: .firstTextBaseline, spacing: 8) {
    Text(model.name)
      .font(.system(size: density.supportingPointSize, weight: .semibold))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .layoutPriority(1)
    Spacer(minLength: 8)
    Text(model.tokensCompact)          // "2.9B" — monospacedDigit, .secondary
    Text(model.spendCompact)           // "$5.1K" — monospacedDigit, .primary, the payload
      .frame(minWidth: 48, alignment: .trailing)
  }
  .font(.system(size: density.supportingPointSize))
  .monospacedDigit()
  // then the proportional bar below the row, full width:
  Capsule().fill(.quaternary)
    .overlay(alignment: .leading) { Capsule().fill(Theme.meterFill(.normal)).frame(width: barWidth) }
    .frame(height: 3)                 // thinner than the meter capsule (5pt) because it's a share, not a limit
  ```

  Row vertical padding 6pt (4pt Compact) — the text-row rhythm. No per-row icons. No chevrons. The top row gets a quiet "Top" tag (`Text("Top").font(.system(size: 10)).foregroundStyle(.tertiary)`) leading the name, or no tag at all — rank is the signal. The hovered row dims its siblings to 0.35 (the `UsageTrendDetail` selection trick), which doubles as the hover affordance.
- **Source note:** 10pt, `.secondary`, the provider's source string ("From your Claude usage history (estimated)" / "From your Cursor usage export" / "From your Codex logs (estimated)"). The `estimated` flag already exists per-provider in `SpendTileMapper`.

**Type ramp:** exactly two sizes — `headerPointSize` (header) and `supportingPointSize` (everything else). Weight-only hierarchy: semibold for names and the period, regular for figures and the source note. This matches the app's existing rule and fixes the concept's inconsistent sizes.

**Chart treatment:** no donut. The per-row proportional `Capsule` is the chart. A single optional "share" number per row ("58%") is the only duplication, and it's the one figure the bar can't label precisely — the same rule the app uses for putting "52% left" as text under the meter.

**Materials:** the `.popover` is system-rendered (real macOS popover chrome, arrow, material). Inside, the background is the system popover material — **do not** paint a custom `cardSurface` behind the list; it would fight the popover. The list rows are borderless, like `UsageTrendDetail`. No Liquid Glass inside.

**Period scoping:** the header's left word *is* the period ("Today" / "Yesterday" / "Last 30 Days"), so the scoping is communicated by the title itself, not a separate subtitle. The hovered row's label already matches — the panel confirms it.

**Sizing:** 280pt wide, fits beside/over the 320pt popover with margin to spare. Height is content-driven (auto-fit), capped at ~6 visible rows before scrolling (rare — most users have ≤5 models).

### Direction B — Header summary bar + list (Storage style)

Same as A, but replace the "Top model …" summary line with a **single full-width proportional stacked bar** in the header that shows the top-3-or-4 models' share in one glance, then the ranked list below. This is the System Settings ▸ Storage pattern (a one-line stacked bar at the top, then the category list).

```
┌──────────────────────────────────────┐
│ Last 30 Days              $8.8K · 9B │
│ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░ │  ← one stacked bar: Opus | GPT-5.5 | Fable | rest
│ ─────────────────────────────────── │
│   Claude 4.8 Opus   $5.1K  58%      │
│   GPT-5.5           $1.7K  19%      │
│   …                                 │
```

- The stacked bar is hand-drawn (`HStack(spacing: 0)` of `RoundedRectangle` segments, or a `Canvas`), each segment in a distinct **system-tinted** color (blue / teal / indigo / gray — not provider-brand colors). This gives the "at a glance" share read that the concept's donut was reaching for, but in a form Apple uses and without duplicating the per-row bars.
- Cost: a second chart form (stacked bar + per-row bars) and a color-per-model decision the app doesn't currently make. The app has so far avoided per-model colors (`Theme.meterFill` is severity-based, one color per row). Introducing a per-model palette is a small but real design-system step.

This direction is **slightly richer than A** and still native, but it adds a per-model color decision and a second chart. Pick it only if the "at-a-glance share" read is worth the extra surface.

### Direction C — Donut + list (the concept, cleaned up)

Keep the donut but make it native: a small (~64pt) hand-drawn `Canvas` donut in the header-right, system-blue for the top model and `.quaternary` for the rest (one color, not per-model), with the top model's percentage in the center at `headerPointSize`. Drop the hero card, the pill, the per-model logos, the chevrons. The list below is Direction A's list.

```
┌──────────────────────────────────────┐
│ Last 30 Days       ╭───╮   $8.8K · 9B│
│                    │58%│             │
│                    ╰───╯             │
│ ─────────────────────────────────── │
│   Claude 4.8 Opus   $5.1K  ▓▓▓▓░░░░ │
│   …                                 │
```

- Pros: keeps the "top driver" read the concept was after, in a compact native form.
- Cons: (1) still duplicates the per-row bar's information (the donut slice and the row bar both say "58%"); (2) a donut in a 280pt popover eats header space and pushes the list down; (3) `SectorMark` (Swift Charts) needs macOS 26+ and a `#available` gate, and the app has **no Swift Charts dependency today** ("No new dependencies without justification", AGENTS.md) — so it would be a hand-drawn `Canvas`/`Path` donut, which is more code than the per-row bars it duplicates; (4) of the four native references (Activity Monitor, Screen Time, Battery, Storage), **none** uses a donut for this exact case. It's the least Apple-native of the three.

---

## 4. Recommendation

**Direction A — the flat ranked list.** Reasons:

1. **It's the native idiom.** Four of the four Apple references for "break a total down by contributor" use a flat ranked list with optional thin bars and no ring chart. The concept's donut + hero card is the thing the owner called "over the top"; A removes exactly that.
2. **It reuses the app's existing hover-detail pattern wholesale.** `UsageSparkline` → `UsageTrendDetail` already ships a `.popover(arrowEdge: .top)` with a `TrendHoverState`-style 400ms/180ms coordinator, a `headerPointSize` title + `supportingPointSize` monospaced readout header, a flat chart body, and a 10pt `.secondary` source note. The model panel is the same skeleton with a ranked list instead of bars — same hover behavior, same dismissal, same fonts, same materials. It will feel like it belongs because it *is* the same component.
3. **It matches the design-language rules the app already enforces.** Two type sizes, weight-only hierarchy, `.primary` for the value / `.secondary` for context, system-blue `Capsule` bars at thin hairline height, borderless rows, no Liquid Glass in the content layer, system popover material as the background. No new colors, no new dependency, no per-model brand assets.
4. **It's provider-neutral by construction.** No provider logos, no "Cursor" in the title or footer — the period name is the title and the source note carries whichever provider was hovered. Works identically for Claude / Codex / Cursor / Grok.
5. **Top-driver emphasis survives, quietly.** Rank position + one "Top model" summary line (the Screen Time "Most used" idiom) carries the emphasis the concept was reaching for, without the pill or the ring. If the list is short (≤3), even the summary line drops — rank alone is enough.
6. **It's buildable on the data that exists.** Per-model aggregation is feasible for all three established spend providers: Cursor's CSV has a `Model` column per row (`CursorUsageCSV.swift:9`), Claude's log scanner carries `Entry.model` per JSONL line (`ClaudeLogUsageScanner.swift:44`), Codex's scanner tracks `currentModel` per event (`CodexLogUsageScanner.swift:42`). The current `SpendTileMapper` aggregates these into per-day totals and discards the per-model dimension; a new sibling mapper can produce a per-model `[ModelShare]` for the hovered period without touching the existing tiles. This is a data-layer addition, not a UI-only change — call it out in the PR plan.

### 4.1 Open decisions to confirm with the owner before implementing

Per AGENTS.md, metric defaults (enabled, primary/secondary, pinned, order) need owner sign-off — and this is a new hover affordance on existing spend rows, so confirm:

- **Trigger:** hover-only (matching Usage Trend), or hover + click? Recommend hover-only with the same 400ms dwell, so it doesn't fight the existing value tooltip (the tooltip shows exact figures; the panel shows the breakdown).
- **Coexistence with the value tooltip:** the spend row already has `.hoverTooltip(data.unboundedValueTooltip)` for exact figures. The panel should anchor to the **value text**, and on reveal the panel supersedes the tooltip (the panel's first row shows the same exact figures). Confirm this is the desired layering.
- **Threshold:** show the panel only when there are ≥2 models in the period? A one-model period has nothing to break down; the tooltip alone is enough.
- **"Other" roll-up:** cap the list at 5 named models + an "Other" row for the long tail (matching the concept). Confirm the cap and the label ("Other" / "Other models").
- **Source-note copy per provider** ("From your Claude usage history (estimated)" vs "From your Cursor usage export" vs "From your Codex logs (estimated)") — confirm wording, especially the `estimated` flag provenance.
- **Density:** the panel should respect `DensitySetting` (Regular/Compact) like every other surface — confirm Compact is supported day-one or deferred.

### 4.2 What to explicitly *not* build

- No per-model brand icons (ship a monogram later only if the owner wants it).
- No donut / `SectorMark` / Swift Charts dependency.
- No hero card, no gradient card-in-card, no "TOP DRIVER" pill.
- No chevrons on rows (no per-model detail screen is in scope).
- No Liquid Glass inside the popover — system popover material only.
- No provider-brand colors — system blue for every share bar, matching the existing meter/sparkline language.
