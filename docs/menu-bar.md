# Menu bar

The strip shows the limits closest to running out, on its own. There is nothing to choose except how many.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a short menu with **Settings** and **Quit**.
Left-click opens the panel.

## What the strip shows

The strip takes the limits from the top of the dashboard's [Running Out](dashboard.md#priority) list, up
to the number set in **Settings → Display → Priority Icons → Show In Menu Bar**, which is 3 at first. Each limit is its
own item: the provider's mark, a short name for the limit, and its value. An account can appear more
than once. The short name drops a trailing word like Models, Usage, or Bot, so Cursor Models reads Cursor.
A positive dollar amount under $1 shows cents, such as `$0.40`. Limits can change order as their
reset times approach, between provider refreshes.

Limits past that number show as a count, like `+7`. Used-up limits and balances never show and never
count.

With nothing running out, or with the setting on **App Icon Only**, the strip shows the app icon. With [Hide
From Screen Share](privacy.md#screen-sharing) on, it also shows the app icon while your screen is shared
or recorded.

When OpenUsage finds an [update](updates.md), the app icon shows at the far right of the strip, after
any count, with a dot at its top-right, whatever the setting. It goes away with the update banner.

When a provider has more than one account, its mark always carries the account name's
initials: the first letter of its first word and of its last, so "Personal" reads P and "Attention
Machine 1" reads A1. Two accounts named alike share a tag; rename one to tell them apart.
