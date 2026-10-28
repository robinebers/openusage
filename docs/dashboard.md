# Dashboard

The panel that opens from the menu bar icon. It is 340 pt wide and shows one provider after another,
each a header above a card.

## Providers and accounts

The header starts with the provider's logo, and one rule names the rest: a provider with one account
puts that account's name on the header, with its plan at the right end of the line, and a provider
with several accounts puts its own name on the header and each account's name and plan inside the card
above its rows. Nothing on the line is ever cut short. The card holds every metric that has data, in
the order you set, one row each.

When you have no accounts, the dashboard shows **Add Account**, which opens the provider chooser.

## Rows

A row is the metric's label, a bar, its value, and its reset, in fixed columns, so every bar in the
panel starts and ends at the same place. The bar fills with what is left (or what is used, under the
Used setting); the value reads `52%`, `$12`, or `320`; the reset reads `1h 26m` or `6d 22h`, or
`Wed 4 PM` under the exact-times setting, and `soon` once it is due. Click any bar row's value to flip
every row between used and left, and any reset to flip between a countdown and the exact time;
**Settings → Usage Display** holds the same two switches. Rest the pointer on a value to read the other
side of it (`48% used` under `52%`), and on a reset to read the other format (the exact time under a
countdown). Rows with a reset tick every 30 seconds, so countdowns stay live between refreshes.

With a reset window, the bar's colour is where your pace lands at the reset: blue while you are on
course to finish with at least 10% to spare, orange when you are on course to land inside the last 10%,
red when you are on course to run out before the reset. A flame before the value marks that last case,
and only that one: a blue or an orange bar never carries a flame. Under 5% used there is too little to
project from, so the bar stays blue. Without a window the colour follows how much is used instead:
blue, orange once 75% is used, red once 90% is. The value takes the bar's colour once the bar is orange
or red. Once a balance is spent, the bar stays red, with no flame. A session window with nothing spent
in it yet shows a full bar and no reset. The colours come from the system palette, so they follow
light, dark, and accessibility settings. Rest the pointer on a bar to read where the pace lands:
`~35% left at reset` on a blue bar, `~92% used at reset` on an orange one, `~12% over limit at reset`
on a red one, `Limit reached` once spent; a bar coloured by how much is used says nothing.

The same pace verdict drives the [notifications](settings.md).

A metric without a limit (a balance, a day's spend, a status) shows its value where the bar would be,
such as `$12.40 left`. A metric the provider has not reported is hidden.

## Resets

Claude and ChatGPT accounts show a **Limit Resets** row with the number of available rate-limit resets
while they have any. The count turns orange when the next reset expires within 7 days and red within
48 hours. Rest the pointer on the count for a moment to see when each reset expires. To spend
one, choose **Use** on it, then **Reset**.

A spinner after an account's name means it is refreshing. A warning icon means its last refresh failed,
and a clock means its values are more than two refresh cycles old. Rest the pointer on the warning or
the clock to read why (the error, or when the values were last updated); the account's right-click
menu starts with the reason too.

## Right-click menus

- A provider's card: **Refresh**, **Manage Accounts…**, **Share Screenshot**, and the provider's links,
  such as **Status Page** and **Usage Dashboard**.
- An account: **Refresh**, **Rename**, **Edit Account…**, and **Share Screenshot**. If the account
  shows a warning or stale icon, the menu starts with the reason. **Show Hidden Metrics** appears when
  you have hidden any.
- A metric: **Star for Menu Bar** (or **Unstar**) and **Hide**. Hiding a metric, here or on the
  Accounts screen, also takes its star off the menu bar. Starring a hidden metric shows it again.

On a card with one account, the header's menu combines the provider and account items.

## Reordering

Drag a provider by its header, an account by its name inside the card, or a metric by its row. A new provider goes to the
bottom of the dashboard and of the Accounts list, and a new account goes to the bottom of its
provider's accounts. The app never sorts providers or accounts for you.

Press **⌘Z** to undo the last layout change (hiding or showing a metric, reordering, starring). Undo is
per session.

## Rename

Double-click an account's name, or choose **Rename** from its menu. The field opens with the whole
name selected. Return or a click elsewhere saves; Esc cancels.

## Share

Rest the pointer on a provider's header and a copy button appears at its right edge; click it, or
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

The bar pinned to the bottom of the panel. On the left: the app version and a live
**Next update in …** countdown you can click (or press **⌘R**) to refresh now. On the right: the
**Options** menu with **Accounts**, **Settings**, **Report an Issue…**, **About OpenUsage**, and
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
