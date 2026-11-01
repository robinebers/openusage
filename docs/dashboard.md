# Dashboard

The panel that opens from the menu bar icon. It is 340 pt wide and has two tabs, **Priority** and
**All Metrics**. It remembers the last one you used and starts on Priority.

When you have no accounts, both tabs show **Add Account**, which opens the provider chooser.

## Priority

Priority shows only what needs you, most urgent first.

**Running Out** lists the limits in trouble, in this order:

1. Limits on course to run out before they reset, soonest to hit the limit first.
2. Limits on course to land inside their last 10%, soonest first.
3. Limits with no pace to go by that are past 75% used, most used first.

Limits that tie keep your dashboard order. Each row shows what's left around the provider's mark, the
limit, the account, the amount, and the time until it resets.

**Used Up** lists what has run out, soonest reset first, with the time until it resets. A balance with
no limit, such as Cursor credits, can never be running out, so it appears here only once it reaches
exactly zero. It comes after every limit with a reset and shows its amount, such as `$0 left`.
Spend totals, day totals, and Limit Resets counts never appear here.

Click a row to open All Metrics at that account. Times tick every 30 seconds.

When nothing is listed, Priority says **All Clear**. When only used-up limits are listed, a short All
Clear row sits above them. Until a limit has data, Priority says **Waiting for Usage** rather than All
Clear.

## All Metrics

One provider after another, each a header above a card. The header is the provider's name and logo,
and every account's name and plan sit inside the card above its rows. An account with no name of its
own shows just its plan. A long account name can be cut short; a plan never is. The card holds every
metric that has data, in the order you set.

### Limits

A limit is its label, its amount, and its reset, over a bar. The bar fills with what is left (or what is
used, under the Used setting); the amount reads `52% left`, `$12 used`, or `320 left`; the reset reads
`Resets 1h 26m`, or `Resets Wed 4 PM` under the exact-times setting, and `Resets soon` once it is
due. Click any amount to flip every row between used and left, and any reset to flip between a countdown
and the exact time; **Settings → Usage Display** holds the same two switches. Rest the pointer on an
amount to read the other side of it (`48% used` under `52% left`), and on a reset to read the other
format (the exact time under a countdown). Rows with a reset tick every 30 seconds, so countdowns stay
live between refreshes.

With a reset window, the bar's colour is where your pace lands at the reset: blue while you are on
course to finish with at least 10% to spare, orange when you are on course to land inside the last 10%,
red when you are on course to run out before the reset. Under 5% used there is too little to project
from, so the bar stays blue. Without a window the colour follows how much is used instead: blue, orange
once 75% is used, red once 90% is. The amount takes the bar's colour once the bar is orange or red. A
used-up limit's amount and track turn red. A session window with nothing spent in it yet shows a full
bar and no reset. The colours come from the system palette, so they follow light, dark, and
accessibility settings. Rest the pointer on a bar to read where the pace lands: `~35% left at reset` on
a blue bar, `~92% used at reset` on an orange one, `~12% over limit at reset` on a red one, `Limit
reached` once spent; a bar coloured by how much is used says nothing.

The same pace verdict drives the [notifications](settings.md).

### Values

A metric without a limit (a balance, a day's spend, a status) shows its label and its value, such as
`$12.40 left`, with any second figure after it, as in `$12.50 · 3K tokens`. A metric the provider has
not reported is left out.

### Resets

Claude and ChatGPT accounts show a **Limit Resets** row with the number of available rate-limit resets
while they have any. The count turns orange when the next reset expires within 7 days and red within
48 hours. Rest the pointer on the count for a moment to see when each reset expires. To spend
one, choose **Use** on it, then **Reset**.

### Account status

A spinner after an account's name means it is refreshing. A warning icon means its last refresh failed,
or that the provider has no usage to report for it, as for a Grok team account. A clock means its
values are more than two refresh cycles old. Rest the pointer on the warning or the clock to read why
(the error or the provider's notice, or when the values were last updated); the account's right-click
menu starts with the reason too.

## Right-click menus

- A provider's card: **Refresh**, **Manage Accounts…**, **Share Screenshot**, and the provider's links,
  such as **Status Page** and **Usage Dashboard**.
- An account: **Refresh**, **Rename**, **Edit Account…**, and **Share Screenshot**. If the account
  shows a warning or stale icon, the menu starts with the reason. A Copilot organization account also
  has **Organization Billing**, which opens the organization's billing page on GitHub. Right-clicking a
  metric opens its account's menu.

## Reordering

On All Metrics, drag a provider by its header, an account by its name inside the card, or a metric by its row. On the Accounts
screen, an account moves past another provider only when both providers have one account; move a
provider with several accounts by its header on the dashboard. A new provider goes to the
bottom of the dashboard and of the Accounts list, and a new account goes to the bottom of its
provider's accounts. The app never sorts providers or accounts for you. After an update from 0.7.x, a
provider in the order you saved in 0.7.x goes to that place instead. See
[Upgrading from 0.7.x](settings.md#upgrading-from-07x).

Press **⌘Z** to undo the last reorder. Undo is per session.

## Rename

Double-click an account's name inside the card, or choose **Rename** from its menu. The field opens with the whole
name selected. Return or a click elsewhere saves; Esc cancels.

## Share

Rest the pointer on a provider's header and its logo becomes a copy button; click it, or
right-click the provider and choose **Share Screenshot**, to copy a PNG of its header and card, with
every account, to the clipboard. On an account inside a card of several, **Share Screenshot** copies
that account alone under the provider's header. The copy button shows a checkmark for a moment on
success, and the footer shows **Copied to clipboard**. The
image shows the header and card at rest, follows your light or dark appearance, and carries a small
OpenUsage mark at the bottom. It uses the account's name when you have set one and leaves an email
out.

## Update banner

When a scheduled update check finds a new version, an **Update Available** card sits above the
provider cards. **Install Update** opens the update window; the ✕ snoozes the card until the next
check. See [Updates](updates.md).

## Footer

The bottom of the panel. On the left: a live **Next update in …** countdown you can click (or press
**⌘R**) to refresh now. On the right: the **⋯** menu with **Accounts**, **Settings**, **Report an Issue…**, **About OpenUsage**, and
**Quit OpenUsage**.

## Keyboard

| Key | Action |
|---|---|
| Return | From the dashboard, open Accounts; from an account's page, return to the list; from the list or Settings, return to the dashboard |
| Esc | Same as Return one level up; from the dashboard, close the panel |
| ⌘Z | Undo the last layout change |
| ⌘R | Refresh now (skips the cache) |
| ⌘, | Open or close Settings |

A global shortcut, recorded in Settings, toggles the panel from anywhere.

## Closing

Closing the panel returns to the dashboard, scrolled to the top.
