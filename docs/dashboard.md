# Dashboard

The popover that opens from the menu bar icon. Providers are sections; each section shows the metrics you've enabled.

## First launch

A fresh install doesn't turn on every provider OpenUsage knows about. It starts with Claude, Codex, and Cursor, then quickly checks which providers have credentials available on your Mac (existing local logins, saved API keys, or supported environment variables — nothing is sent anywhere) and switches to exactly that set. If nothing is found, the Claude/Codex/Cursor starter set stays. A one-time card at the top of the dashboard explains this and points to **Customize**, where you can turn any provider on or off; the card stays until you close it with its ✕ button.

This full detection only happens on a brand-new install. Updates never change the providers you already have on or off — but when an update ships a provider you've never seen, the same local check runs once for just that provider and turns it on only if you actually have the tool. See [Which Providers Are On](provider-enablement.md) for the full lifecycle.

Each provider card leads with its **Always Visible** metrics. Any metrics you've moved below the **On Demand** line are tucked away behind the in-card caret — click it to reveal them below the caret, click again to collapse. Open cards stay open across popover closes and app restarts. A provider with neither On Demand metrics nor quick links shows no caret.

When you expand a card, the tucked-away metrics open below the caret as a single-column list, so each detail row keeps the full card width.

A provider card can also show **quick-link buttons** pinned at the bottom of its expanded section — Status, Console, Dashboard, and the like — that open the provider's own pages in your default browser. They're part of the expander, so collapsing the caret hides them along with the tucked-away metrics. Buttons lay out up to three across, wrapping to a second row when there are more.

## Total Spend

When any enabled provider tracks daily spend (Claude, Codex, Cursor, or Grok), a card sits above the provider sections. The title is a pull-down menu for **Cost**, **Cost/MTok**, or **Tokens** (Cost is the default; the choice sticks across restarts). A capsule switcher flips the period between **Today**, **Yesterday**, and **30 Days**. The ring, center total, and ranked legend follow the selected metric:

- **Cost** — each segment is that provider's share of combined dollars (biggest spender first).
- **Cost/MTok** — each segment is sized by that provider's dollars-per-million-tokens rate; the center is the blended rate across providers that have both spend and tokens; the legend lists each provider's own rate.
- **Tokens** — each segment is that provider's share of combined tokens.

The ring center is always two short lines — a compact number on top and a quiet unit underneath (`$533` / `dollars`, `12.4` / `million`, or `$1.37` / `MTok`) — so Cost/MTok and big totals stay readable in the hole. Cost modes keep the `$` on the number. Hover the center for the exact one-line figure (and a note when any contributor's dollars are a local estimate — Cost and Cost/MTok only). Each provider keeps a fixed color drawn from its brand (Claude's terracotta, OpenAI's green, and so on), and even a tiny share keeps a visible sliver of the ring. Providers with nothing for the selected metric simply don't appear — they're never counted as zero. (An enabled provider counts even if you've hidden its own spend rows in Customize; other dollar rows, like OpenRouter's API spend, never mix in.) The header's share icon (or right-clicking the card) copies a branded PNG of the ring to your clipboard, just like sharing a provider card. The header also carries a small ⓘ naming the providers that feed the total. A period with nothing to show for the active metric shows a quiet empty state instead of hiding the card. Don't want the card at all? Turn it off with **Show Total Spend** at the top of [Settings](settings.md).

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

**Metrics without a limit** (daily spend, balances) show as a single line like `$4.08 spent` or `1.2M tokens`. The Today / Yesterday / Last 30 Days rows combine cost and tokens (`$4.08 · 1.2M tokens`) and can be turned on or off in Customize. A day with no usage reads "No data" rather than a misleading `$0.00 · 0 tokens` — the same as when the source can't be loaded at all. Big numbers are abbreviated to keep rows tidy (`$2.06K`, `1.5B`) — hover the value to see the exact figures and source note, such as a local estimate.

For Claude, Codex, Cursor, and Grok spend rows, the value gently highlights when you point at it, signaling it's interactive; hovering it for a moment opens a small model breakdown for that period: a ranked list of models, each showing its name and spend on one line, its share percentage and tokens on the next, and a thin share bar. Cursor groups its per-thinking-effort export slugs (like `claude-opus-4-8-thinking-max`) under the base model. Long tails fold into **Other** — anything past the top named models or under 5% of the period. Models no pricing source can price don't appear here (or in the row's totals) at all; the row's warning triangle names them instead (see [Pricing](pricing.md)).

**Usage Trend** (Claude, Codex, Cursor, and Grok) is a small bar chart of the last 30 days of token usage — one bar per day, drawn from the same source as that provider's spend rows (local logs for Claude, Codex, and Grok; Cursor's usage export for Cursor). **Hover it** for the peak day, the date range, and the source. It's on by default; turn it off or reorder it from Customize like any other metric. It can't be starred for the menu bar — the strip shows single values, not a chart.

Rows with a reset date tick every 30 seconds, so countdowns and pace stay live between refreshes.

## Right-click menus

Every row: **Hide · Star for menu bar / Unstar · Refresh \<provider\> · Customize…** (Customize opens straight to that provider's metrics.)
Provider headers: **Hide \<provider\> · Refresh \<provider\> · Customize…** (Hide turns the whole provider off; turn it back on in Customize. Customize opens straight to that provider's metrics.) plus **Share Screenshot** (see below).

## Share

Copy a clean, branded PNG of one provider's usage to your clipboard, ready to paste into a chat, a tweet, or a doc. There are two ways to reach it:

- Right-click a provider header and choose **Share Screenshot**.
- Open the footer's **Options** menu and choose **Share Screenshot** ▸ *\<provider\>*. The submenu lists every provider currently showing on the dashboard.

The image is a flexible-height PNG using the app's look — the provider's mark and name up top, the metric rows you currently see for that provider, and a small OpenUsage mark centered at the bottom. It follows your Light/Dark appearance and shows everything on the card as-is (nothing is hidden or blurred).

## Footer

The bar pinned to the bottom of the popover. On the left: the app version, and a live "Next update in …" countdown you can click (or press **⌘R**) to refresh right away. On the right: an **Options** menu button. It holds everything in one place — **Customize**, **Settings**, **Share Screenshot** (submenu of providers), **Check for Updates…**, **About OpenUsage**, and **Quit OpenUsage**.

## Customize

Open Customize from the footer's **Options** menu (or press **Return**). It's a two-level screen: a list of providers, then a provider's detail.

The **provider list** shows every provider with a switch to turn it on or off, a count of its metrics, and a chevron into its detail. Turn a provider off and it stays in the list, greyed — its metrics hide from the dashboard and menu bar but keep their setup for when you turn it back on. Drag enabled providers by their grip to reorder; tap a row to open its detail. On a fresh install only the providers detected on your Mac start on (see "First launch" above); this list is where you add the rest.

A provider's **detail** has a back button and provider-specific Reset control in its top bar, followed by two metric sections: **Always Visible** (shown on the dashboard card) and **On Demand** (tucked behind the card's caret). Each metric row has a drag grip, its name, an always-visible star for the menu bar, and an on/off switch. Drag a metric into the other card—or onto one of that card's rows—to move it between Always Visible and On Demand. An empty card shows a dashed **Drag metrics here** target. You can star up to two metrics per provider. OpenRouter and Z.ai also show an **API Key** section here, where you can add, replace, reveal, or clear that provider's key.

Drag-reorder also works directly on the dashboard — drag a row within its provider, drag it across the caret boundary while the card is open, or drag a provider header to reorder sections. On a Force Touch trackpad you'll feel a light tap each time the dragged item snaps into a new slot.

The default reset layout keeps each provider's core quota meters and Usage Trend always visible, then tucks balances, reset details, and spend-history rows on demand. Optional detail rows like Claude Sonnet and Cursor Requests/Credits stay off by default, but start on demand if you enable them.

Made a change you didn't mean to? Press **⌘Z** to undo — it works anywhere in the popover (the dashboard and Customize alike) and steps back through your recent customization changes one at a time: hiding or showing a metric, reordering metrics or whole providers, starring or unstarring, and moving a metric across the divider all undo. Each step restores the exact previous arrangement. Undo is per-session (it starts fresh after a relaunch), and resetting clears it.

When OpenUsage ships a new default metric, existing layouts get it once. If you turn it off, it stays off. A provider's **Reset** button (top right of its detail) restores that provider's default metrics, order, menu-bar stars, and which metrics start on demand, but leaves other providers and the provider order untouched. The **Reset All Customization** button (top right of the provider list) does the same for every provider at once, restores the default provider order, and re-detects your installed tools — turning providers back on for exactly the tools set up on your Mac, just like first launch (see [Which Providers Are On](provider-enablement.md)). It asks for confirmation first, since it wipes the whole layout and re-detects providers, and can't be undone.

## Keyboard

| Key | Action |
|---|---|
| Return | From the dashboard, open Customize; from a provider detail, return to the provider list; from the provider list or Settings, return to the dashboard |
| Esc | From a provider detail, return to the provider list; from the provider list or Settings, return to the dashboard; from the dashboard, close the popover |
| ⌘Z | Undo the last customization change (app-wide; repeat to step back) |
| ⌘R | Refresh now from the dashboard or Settings (skips the cache) |
| ⌘, | Open / close Settings (in the popover) |

A global shortcut (recorded in Settings) toggles the popover from anywhere.

## Closing

Closing the popover resets navigation state: scroll position returns to the top and Customize / Settings close. Provider cards remember whether their expand caret was open.
