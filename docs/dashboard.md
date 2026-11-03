# Dashboard

The panel that opens from the menu bar icon. It is 340 pt wide and has two tabs, **Priority** and
**All Usage**. Opening it from the menu bar or global shortcut uses the Default Tab in Settings,
including the first time after launch. The default is Priority. Clicking a usage notification opens All Usage.

When you have no accounts, both tabs show **Add Account**, which opens the provider chooser.

## Priority

Priority shows only what needs you, most urgent first.

**Pinned** comes first when you have pinned a metric on its account's page. It lists every pinned metric
that has data, whatever its reading, in your dashboard order: account by account, then each account's
metric order. A pinned metric appears only here, never again under Running Out or Used Up.

**Running Out** lists every limit with 30% or less left, whose bar is orange or red. Time never decides
what's listed, only the order: what would run out soonest at your current pace comes first, then limits
with no pace to go by, least left first.

Limits that tie keep your dashboard order. Each row shows the limit's level around the provider's mark, filling under Used or Left like its bar, the
limit, the account, the amount, and the time until it resets.

**Used Up** lists what has run out, soonest reset first, with the time until it resets. A balance with
no limit, such as Cursor credits, can never be running out, so it appears here only once it reaches
exactly zero. It comes after every limit with a reset and shows its amount, such as `$0 left`.
Spend totals, day totals, and Limit Resets counts never appear here.

Click an amount to flip it between used and left, and a time to flip it between a countdown and the exact
time, the same switches as All Usage. Times tick every 30 seconds.

**All Clear** means every account has a current reading and none of its limits is running low. Used-up
limits still appear below it. **Waiting for Usage** means a first reading is pending. If every account
has reported and none has a limit to monitor, **No Reported Limits** links to All Usage.

When a refresh fails, values go stale, or a provider sends a notice, a **Needs Attention** row names the
account. **Fix** opens its page, which gives the reason and the way to fix it. Last-known limits that are
running low or used up stay visible.

## All Usage

One provider after another, each a header above a card. The header is the provider's name and logo,
and every account's name and plan sit inside the card above its rows. With several accounts, each
keeps a name you can drag. The card holds every metric that has data and that you have not hidden, in
the order you set.

## Hiding, pinning, and ordering metrics

An account's page in **Accounts** lists all of its metrics, in its order. Turn a metric's switch off to
hide it everywhere: All Usage, Priority, the menu bar, and notifications. Click the pin beside the switch
to list the metric under Pinned at the top of Priority; a hidden metric can't be pinned, and hiding a
pinned metric unpins it. Drag a metric by its handle to change where it sits within the account. These
choices are saved and survive a restart; removing an account removes its pins. A new account
shows every metric, in the provider's order. If you hide every metric of every account, the dashboard
says so and points you to Accounts.

### Limits

A limit is one line: its label, a level bar, its amount, and its reset, with the bars lined up down the
panel. The bar fills with what is left (or what is used, under the Used setting); the amount reads
`52%`, `$12.40`, or `320`. The reset reads `1h 26m`, or `Wed 4 PM` under the exact-times setting, and
`soon` once it is due. Click any amount to flip every row between used and left, and any reset to flip
between a countdown and the exact time; **Settings → Display** holds the same two switches. Rest the
pointer on an amount to read the other side of it (`48% used` next to `52%`), and on a reset to read
the other format (the exact time next to a countdown). Rows with a reset tick every 30 seconds, so
countdowns stay live between refreshes.

A bar's colour follows only what's left: blue, orange at 30% left, red at 10% left. The amount takes the
bar's colour once the bar is orange or red. A
used-up limit's amount and reset turn red, and its row fades when its bar is empty. A session window with nothing spent in it yet shows a full
bar and no reset. The colours come from the system palette, so they follow light, dark, and
accessibility settings. Rest the pointer on a bar to read where your pace lands: `~35% left at reset`,
`~92% used at reset`, `~12% over limit at reset`, or `Limit reached` once spent; a limit with no reset
window says nothing.

The same pace verdict drives the [notifications](settings.md).

### Values

A metric without a limit (a balance, a day's spend, a status) shows its label and its value, such as
`$12.40 left`, with any second figure after it, as in `$12.50 · 3K tokens`. A metric the provider has
not reported is left out.

### Resets

Claude and ChatGPT accounts show a **Limit Resets** row with the number of available rate-limit resets
while they have any. The count turns orange when the next reset expires within 7 days and red within
48 hours. Hover over the count to preview the expiry dates, or click the count to keep them open.
With the count focused, press Space. To spend a reset, choose **Use**, then **Reset**.

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

On All Usage, drag a provider by its header, an account by its name inside the card, or a metric by its row. An
account's page orders its metrics too. On the Accounts
screen, an account moves past another provider only when both providers have one account; move a
provider with several accounts by its header on the dashboard. A new provider goes to the
bottom of the dashboard and of the Accounts list, and a new account goes to the bottom of its
provider's accounts. The app never sorts providers or accounts for you. After an update from 0.7.x, a
provider in the order you saved in 0.7.x goes to that place instead. See
[Upgrading from 0.7.x](settings.md#upgrading-from-07x).

Press **⌘Z** to undo the last reorder. Undo is per session.

## Usage Details

Hover over a Today, Yesterday, or similar figure to preview its details. To keep them open,
click the figure or focus it and press Space. VoiceOver can activate the figure as a button.
After relaunch, the total opens with its last saved breakdown. If only the total was saved,
the panel shows it with the account's refresh status. The details update in place when they arrive.
When a saved breakdown is from an earlier reporting day, its preview and copied image show the date.

A range adds up the days that supplied each figure; a figure the provider reported for the whole range
wins. A quiet day or a day that could not be read adds nothing. For example, Last 30 Days can show the
older days while Today is unavailable.

The details show charges, tokens and the top five models, with the remaining named models grouped
under **Other**. A bar shows the token split when the parts add up to the total. **Top Models** ranks
the costs or tokens the provider attributed to each model, even when some usage has no model name.

For ChatGPT, each percentage is the model's share of the credits or turns reported for the range.
Named models can add up to less than 100% when attribution is partial.

Click the copy button in the corner to copy a PNG of the details, with the provider's name and
whichever of Cost or Tokens is showing, without the switch.

When every figure the provider reported for a range is zero, such as a `$0` charge and nothing else,
the details say "<Provider> didn't report any data for this range." for every provider. Such a range
has nothing to copy.

## Rename

Double-click an account's name inside the card, or choose **Rename** from its menu. The field opens with the whole
name selected. Return or a click elsewhere saves; Esc cancels.

## Share

Rest the pointer on a provider's logo and it becomes a copy button; click it, or
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
**⌘R**) to refresh now, once there's an account to refresh. On the right: on Priority, when it lists
anything, a button that copies the tab as a PNG with emails hidden, then the **⋯** menu with **Accounts**, **Settings**, **Report an Issue…**, **About OpenUsage**, and
**Quit OpenUsage**.

## Keyboard

| Key | Action |
|---|---|
| Return | From the dashboard, open Accounts; from an account's page, return to the list; from the list or Settings, return to the dashboard |
| Esc | Same as Return one level up; from the dashboard, close the panel |
| Space | Open the details for a focused usage-history figure or Limit Resets count |
| ⌘Z | Undo the last layout change |
| ⌘R | Refresh now (skips the cache) |
| ⌘, | Open or close Settings |

A global shortcut, recorded in Settings, toggles the panel from anywhere.

## Closing

Closing the panel returns to the dashboard, scrolled to the top.
