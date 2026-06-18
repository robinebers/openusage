# Dashboard

The popover that opens from the menu bar icon. Providers are sections; each section shows the metrics you've enabled.

## Rows

**Metrics with a limit** (session, weekly, credits with a cap) show a progress bar with:

- A fill whose color is a verdict on the whole window, based on your current burn rate: blue while you're on course to finish with at least 10% to spare, yellow when you're projected to land inside the last 10% with a little cushion to spare, red when you're projected to run out before the reset — or to finish right at the limit with nothing to spare. So a half-full bar burning too fast is already red, and a nearly-drained bar coasting to the reset stays blue. Bars without a reset window (like a credit balance), and fresh windows too young to project, color by the level itself instead: yellow once 80% is used, red once 10% or less is left. The colors come from the system palette, so they adapt to light/dark and accessibility settings, and they never flip with the Used/Left toggle.
- A headline like `52% left` or `48% used`. **Click it** to flip between Used and Left everywhere — hovering shows the opposite reading.
- A reset label like `Resets in 3h 25m` or `Resets today at 6:38 PM`. **Click it** to flip between countdown and exact time everywhere — hovering shows the other format.
- A blue bar carries nothing extra. A yellow bar adds two things: a small tick next to the fill's edge that fences off your projected cushion — the spare-width sliver between the edge and the tick (just outside the fill in Used view, the last slice of the fill in Left view) is what's left over at reset if you keep this rate — and a quiet `~3% spare` note right-aligned next to the metric name. That cushion is always at least 1%; if you're projected to finish with nothing to spare it turns red instead (so a yellow bar never reads `~0% spare`). Both disappear when you're comfortably within limits or already past saving.
- A red bar swaps the note for a red flame next to the metric name with the projected run-out time — `Limit in 3h 5m` or `Limit today at 11:49 PM`, following the same countdown/exact format as the reset label. **Click it** to flip the format everywhere, just like clicking the reset label. When you're projected to finish right at the limit — no run-out before the reset, just no cushion left — the flame shows alone with no time.
- Once the balance is spent — actually empty, or so close it rounds to `0` (like `0% left` or `$0.00`) — the bar stays red and the flame reads `Limit reached`, no matter how gentle the burn rate looked. A visibly empty bar never shows a calmer color.
- **Hover the bar**, the spare note, or the flame for the pace projection at reset — the one number not already on the row: a blue bar shows the cushion you're on course to finish with (`~35% left at reset`), a yellow bar the usage it complements the spare note with (`~92% used at reset`), a red bar how far past the limit you're projected to land (`~12% over limit at reset`, or `~100% used at reset` when you're projected to finish right at it). Once spent it reads `Limit reached`.

**Metrics without a limit** (daily spend, balances) show as a single line like `$4.08 spent` or `1.2M`. The daily spend rows (Today / Yesterday / Last 30 Days) come in three flavors you can add from Customize — cost (`$4.08 spent`), tokens (`1.2M`), or both (`$4.08 · 1.2M`). Big numbers are abbreviated to keep rows tidy (`$2.06K`, `1.5B`) — **hover the row** to see the exact figures. A small ⓘ next to the name means a dollar figure is estimated locally rather than billed — hover it for details; token counts are measured, so they carry no ⓘ.

Rows with a reset date tick every 30 seconds, so countdowns and pace stay live between refreshes.

## Right-click menus

Every row: **Pin to menu bar / Unpin · Hide · Show what's used/left · Show exact reset times/reset countdowns · Refresh \<provider\> · Customize…**
Provider headers: **Refresh \<provider\> · Customize…**

## Customize

The More button's **Customize Metrics** item (or pressing **Return**) opens Customize: toggle metrics on/off, add ones that aren't placed yet, pin metrics for the menu bar, and drag to reorder. Drag-reorder also works directly on the dashboard — drag a row within its provider, or drag a provider header to reorder sections. On a Force Touch trackpad you'll feel a light tap each time the dragged item snaps into a new slot.

## Keyboard

| Key | Action |
|---|---|
| Return | Open / close Customize |
| Esc | Back out of Customize or Settings; from the dashboard, close the popover |
| ⌘R | Refresh now (skips the cache) |
| ⌘, | Open / close Settings (in the popover) |

A global shortcut (recorded in Settings) toggles the popover from anywhere.

## Closing

Closing the popover resets it: scroll position returns to the top and Customize / Settings close, so it always reopens in a clean state.
