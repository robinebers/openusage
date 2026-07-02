# Dashboard

The popover that opens from the menu bar icon. Providers are sections; each section shows the metrics you've enabled.

Each provider card leads with its **Always Visible** metrics. Any metrics you've moved below the **On Demand** line are tucked away behind the in-card caret — click it to reveal them below the caret, click again to collapse. Open cards stay open across popover closes and app restarts. A provider with nothing tucked away shows no caret.

When you expand a card, the tucked-away metrics open below the caret as a single-column list, so each detail row keeps the full card width.

A provider card can also show **quick-link buttons** pinned at the bottom of its expanded section — Status, Console, Dashboard, and the like — that open the provider's own pages in your default browser. They're part of the expander, so collapsing the caret hides them along with the tucked-away metrics. Buttons lay out up to three across, wrapping to a second row when there are more.

## Rows

**Metrics with a limit** (session, weekly, credits with a cap) show a progress bar with:

- A fill whose color is a verdict on the whole window, based on your current burn rate: blue while you're on course to finish with at least 10% to spare, yellow when you're projected to land inside the last 10% with a little cushion to spare, red when you're projected to run out before the reset — or to finish right at the limit with nothing to spare. So a half-full bar burning too fast is already red, and a nearly-drained bar coasting to the reset stays blue. Bars without a reset window (like a credit balance), and fresh windows too young to project, color by the level itself instead: yellow once 80% is used, red once 10% or less is left. The colors come from the system palette, so they adapt to light/dark and accessibility settings, and they never flip with the Used/Left toggle.
- A headline like `52% left` or `48% used`. **Click it** to flip between Used and Left everywhere — hovering shows the opposite reading.
- A reset label like `Resets in 3h 25m` or `Resets today at 6:38 PM`. **Click it** to flip between countdown and exact time everywhere — hovering shows the other format.
- A blue bar carries nothing extra by default. With **Always Show Pacing** on (Settings), it also shows an even-pace tick on the bar and a quiet `~35% left at reset` note next to the metric name.
- A yellow bar adds a `~3% spare` note right-aligned next to the metric name, plus the even-pace tick on the bar (where usage would sit if you burned evenly across the window). That cushion is always at least 1%; if you're projected to finish with nothing to spare it turns red instead (so a yellow bar never reads `~0% spare`).
- A red bar swaps the note for a red flame next to the metric name with the projected run-out time — `Limit in 3h 5m` or `Limit today at 11:49 PM`, following the same countdown/exact format as the reset label — and still shows the even-pace tick on the bar. **Click the time** to flip the format everywhere, just like clicking the reset label. When you're projected to finish right at the limit — no run-out before the reset, just no cushion left — the flame shows alone with no time.
- Once the balance is spent — actually empty, or so close it rounds to `0` (like `0% left` or `$0.00`) — the bar stays red and the flame reads `Limit reached`, no matter how gentle the burn rate looked. A visibly empty bar never shows a calmer color.
- **Hover the bar**, the spare note, or the flame for the pace projection at reset — the one number not already on the row: a blue bar shows the cushion you're on course to finish with (`~35% left at reset`), a yellow bar the usage it complements the spare note with (`~92% used at reset`), a red bar how far past the limit you're projected to land (`~12% over limit at reset`, or `~100% used at reset` when you're projected to finish right at it). Once spent it reads `Limit reached`.

**Metrics without a limit** (daily spend, balances) show as a single line like `$4.08 spent` or `1.2M tokens`. The daily spend rows (Today / Yesterday / Last 30 Days) come in three flavors you can add from Customize — cost (`$4.08 spent`), tokens (`1.2M tokens`), or both (`$4.08 · 1.2M tokens`). A day with no usage reads "No data" rather than a misleading `$0.00 · 0 tokens` — the same as when the source can't be loaded at all. Big numbers are abbreviated to keep rows tidy (`$2.06K`, `1.5B`) — hover the value to see the exact figures and source note, such as a local estimate.

**Usage Trend** (Claude, Codex, and Grok) is a small bar chart of the last 30 days of token usage — one bar per day, drawn from the same source as that provider's spend rows (the provider's local logs). **Hover it** for the peak day, the date range, and the source. It's on by default; turn it off or reorder it from Customize like any other metric. It can't be starred for the menu bar — the strip shows single values, not a chart.

Rows with a reset date tick every 30 seconds, so countdowns and pace stay live between refreshes.

## Right-click menus

Every row: **Hide · Star for menu bar / Unstar · Refresh \<provider\> · Customize…** (Customize opens straight to that provider's metrics.)
Provider headers: **Hide \<provider\> · Refresh \<provider\> · Customize…** (Hide turns the whole provider off; turn it back on in Customize. Customize opens straight to that provider's metrics.) plus **Share Screenshot** (see below).

## Share

Copy a clean, branded PNG of one provider's usage to your clipboard, ready to paste into a chat, a tweet, or a doc. There are two ways to reach it:

- Right-click a provider header and choose **Share Screenshot**.
- Open the footer's **⌄** menu and choose **Share Screenshot** ▸ *\<provider\>*. The submenu lists every provider currently showing on the dashboard.

The image is a flexible-height PNG using the app's look — the provider's mark and name up top, the metric rows you currently see for that provider, and a small OpenUsage mark centered at the bottom. It follows your Light/Dark appearance and shows everything on the card as-is (nothing is hidden or blurred).

## Footer

The bar pinned to the bottom of the popover. On the left: the app version, and a live "Next update in …" countdown you can click (or press **⌘R**) to refresh right away. On the right: a **Customize** button paired with a **⌄** menu. The menu holds the app-level actions — **Settings**, **Share Screenshot** (submenu of providers), **Check for Updates…**, **About OpenUsage**, and **Quit OpenUsage**.

## Customize

Open Customize from the footer's **Customize** button (or press **Return**). It's a two-level screen: a list of providers, then a provider's detail.

The **provider list** shows every provider with a switch to turn it on or off, an Active/Inactive status, a count of its metrics, and a chevron into its detail. Turn a provider off and it stays in the list, greyed — its metrics hide from the dashboard and menu bar but keep their setup for when you turn it back on. Drag providers by their grip to reorder; tap a row to open its detail.

A provider's **detail** has a header (the same on/off switch) and two metric sections: **Always Visible** (shown on the dashboard card) and **On Demand** (tucked behind the card's caret). Each metric row is a switch with its name beside it, a star to add it to the menu bar, and a drag grip. Drag a metric across the dashed divider between the sections to move it between Always Visible and On Demand, or drag it onto a row on the other side. You can star up to two metrics per provider for the menu bar. Providers that need an API key (OpenRouter today) show an **API Key** section here too — add, edit, or clear the key for just that provider.

Drag-reorder also works directly on the dashboard — drag a row within its provider, drag it across the caret boundary while the card is open, or drag a provider header to reorder sections. On a Force Touch trackpad you'll feel a light tap each time the dragged item snaps into a new slot.

The default reset layout keeps each provider's core quota meters and Usage Trend always visible, then tucks balances, reset details, and spend-history rows on demand. Optional detail rows like Claude Sonnet and Cursor Requests/Credits stay off by default, but start on demand if you enable them.

Made a change you didn't mean to? Press **⌘Z** to undo — it works anywhere in the popover (the dashboard and Customize alike) and steps back through your recent customization changes one at a time: hiding or showing a metric, reordering metrics or whole providers, starring or unstarring, and moving a metric across the divider all undo. Each step restores the exact previous arrangement. Undo is per-session (it starts fresh after a relaunch), and resetting clears it.

When OpenUsage ships a new default metric, existing layouts get it once. If you turn it off, it stays off. A provider's **Reset** button (top right of its detail) restores that provider's default metrics, order, menu-bar stars, and which metrics start on demand, but leaves other providers and the provider order untouched. The **Reset All Customization** button (top right of the provider list) does the same for every provider at once and also restores the default provider order — it asks for confirmation first, since it wipes the whole layout and can't be undone.

## Keyboard

| Key | Action |
|---|---|
| Return | Open / close Customize |
| Esc | Back out of Customize or Settings; from the dashboard, close the popover |
| ⌘Z | Undo the last customization change (app-wide; repeat to step back) |
| ⌘R | Refresh now (skips the cache) |
| ⌘, | Open / close Settings (in the popover) |

A global shortcut (recorded in Settings) toggles the popover from anywhere.

## Closing

Closing the popover resets navigation state: scroll position returns to the top and Customize / Settings close. Provider cards remember whether their expand caret was open.
