# macOS Widgets

OpenUsage includes a native widget for the desktop and Notification Center. Each instance shows one
account; add more instances to keep several accounts visible.

## Add and configure one

1. Launch OpenUsage and add an account from **Accounts**.
2. Open the macOS widget gallery and add the OpenUsage usage widget.
3. Edit the widget to choose an account. Its name includes the provider and your account label.
4. Choose the small, medium, or large size.

The widget follows that account's shown metrics and saved order in OpenUsage. Small widgets show up
to two metrics, medium up to four, and large up to eight.
A widget without a saved selection uses the first account in your saved order.

Clicking a widget opens the popover at that account. When all its metrics are hidden, the click opens
its Accounts detail so you can show them again. A widget without shared data, or whose account was
removed from OpenUsage, opens the dashboard for recovery.

## Updates and stale data

The widget never reads credentials or contacts providers itself. OpenUsage handles its normal
five-minute refresh and shares display-ready values with WidgetKit. Keep OpenUsage running for
updates; **Launch at Login** is the easiest way to do that. Account names, visibility and order follow
changes in the app too.

When OpenUsage is closed, the widget keeps the last good values and marks them **Outdated** after
about 30 minutes. A refresh failure also keeps the last good values and shows a generic warning;
open the popover for the account's detailed error and recovery steps.

Removing an account removes its shared values. Its widget reports that the account is unavailable
instead of silently switching to another account. Edit the widget to select another one.

Unreadable shared data shows **Unable to Read Data**; data requiring a newer widget shows
**Update Required**. Both states appear even before an account is selected.

WidgetKit controls the exact redraw time, so a widget can update later than the in-app refresh.
Reset countdowns continue updating without another provider request.
