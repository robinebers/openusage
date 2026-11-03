# Dashboard

The panel that opens from the menu bar icon. It has two tabs, Priority and All Usage.

- The menu bar icon and the global shortcut open the Default Tab from Settings (Priority by
  default). A usage notification opens All Usage.
- With no accounts, both tabs show **Add Account**.
- Closing the panel returns it to the dashboard, scrolled to the top.

## Priority

Priority shows only what needs you, most urgent first.

- **Pinned** comes first, with every pinned metric that has data. A pinned metric that's running
  out moves to Running Out until it recovers.
- **Running Out** lists every limit with 30% or less left. What would run out soonest at your
  current pace comes first, then limits with no pace, least left first.
- **Used Up** lists what has run out, soonest reset first. A balance with no limit, such as Cursor
  credits, shows here only at exactly zero.
- **All Clear** shows under Running Out when every account has a current reading and nothing is
  running low. It waits for accounts that haven't reported yet.
- **Needs Attention** names an account whose refresh failed or whose provider sent a notice.
  **Fix** opens the account's page with the reason and how to fix it.

Ties keep your dashboard order. If no account has a limit to monitor, **No Reported Limits** links
to All Usage.

## All Usage

One card per provider, with each account's name, plan, and metrics inside. The card holds every
metric with data that you haven't hidden, in your order.

- Time ranges always show, at 0 when the provider reports nothing.
- Balances show even at `$0 left`.
- Extra Usage shows while the provider has it on, even at `$0`, and hides while it's off.
- A metric without a limit (a balance, a day's spend, a status) shows its value, such as
  `$12.40 left`.

### Limits

A limit row shows its label, a bar, its amount, and the time until it resets.

- Click any amount, on either tab, to flip every row between used and left. Click any reset to flip
  between a countdown and the exact time. **Settings → Display** has the same two switches.
- Countdowns update every 30 seconds.
- Hover over a bar to see where your current pace lands at reset. The same pace drives the
  [notifications](settings.md).

### Resets

Claude and ChatGPT accounts show a **Limit Resets** row while they have rate-limit resets available.
Hover over the count to see the expiry dates, or click it to keep them open. To spend a reset,
choose **Use**, then **Reset**.

### Account status

- A spinner after an account's name means it's refreshing.
- A warning means its last refresh failed, or the provider has no usage to report for it.
- A clock means its values are more than two refresh cycles old.

Hover over the warning or the clock, or right-click the account, to see why.

## Hiding, pinning, and ordering metrics

An account's page in **Accounts** lists all of its metrics.

- Turn a metric's switch off to hide it everywhere: All Usage, Priority, the menu bar, and
  notifications.
- Click the pin, or right-click the metric on the dashboard and choose **Pin**, to list it under
  Pinned on Priority. A hidden metric can't be pinned.
- Drag a metric by its handle to move it within the account.
- A new account shows every metric, in the provider's order.

## Right-click menus

- A provider: **Refresh**, **Manage Accounts…**, **Share Screenshot**, and links such as **Status
  Page** and **Usage Dashboard**.
- An account: **Refresh**, **Rename**, **Edit Account…**, and **Share Screenshot**. A Copilot
  organization account also has **Organization Billing**.
- A metric: **Pin** or **Unpin**, then its account's menu.

## Reordering

- On All Usage, drag a provider by its header, an account by its name, or a metric by its row.
- On the Accounts screen, an account moves past another provider only when both providers have one
  account.
- A new provider goes to the bottom, and a new account goes to the bottom of its provider. The app
  never sorts providers or accounts for you.
- Coming from 0.7.x? See [Upgrading from 0.7.x](settings.md#upgrading-from-07x).
- Press **⌘Z** to undo the last layout change.

## Usage details

Hover over a Today, Yesterday, or similar figure to preview its details. Click it to keep them open.

- The details show charges, tokens, and the top five models, with the rest under **Other**.
- For ChatGPT, each percentage is the model's share of the credits or turns for the range.
- A range adds up the days that supplied each figure. A quiet or unreadable day adds nothing.
- The copy button copies a PNG of the details.

## Share

Click a provider's logo, or choose **Share Screenshot**, to copy a PNG of its card. On one account
in a card of several, it copies only that account. Emails are left out.

## Update banner

When a scheduled check finds a new version, an **Update Available** card shows above the provider
cards. **Install Update** opens the update window, and ✕ hides the card until the next check. See
[Updates](updates.md).

## Footer

- **Next update in …** counts down to the next refresh. Click it or press **⌘R** to refresh now.
- On Priority, a button copies the tab as a PNG with emails hidden.
- The **⋯** menu has **Accounts**, **Settings**, **Check for Updates…**, **Report an Issue…**,
  **About OpenUsage**, and **Quit OpenUsage**.

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
