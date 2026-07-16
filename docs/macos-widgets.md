# macOS Widgets

OpenUsage includes a native macOS widget for the desktop and Notification Center. Each widget instance
shows one provider; add more instances to keep several providers visible.

## Add and configure one

1. Launch OpenUsage at least once so it can publish the first usage snapshot.
2. Open the macOS widget gallery and add **Provider Usage**.
3. Edit the widget to choose Claude, Codex, Cursor, or any other enabled provider.
4. Choose the small, medium, or large size.

The widget follows the provider's enabled metrics and saved order in OpenUsage. Small and medium focus
on the metrics shown above the provider's expand caret; large widgets can also include metrics marked
"Shown on expand." Usage Trend charts stay in the popover.

Clicking a widget opens the OpenUsage popover at that provider. If the provider is off or has no enabled
widget-compatible metrics (for example, only Usage Trend remains), it opens the provider's Customize
screen instead.

## Updates and stale data

The widget never reads credentials or contacts providers itself. OpenUsage remains responsible for its
normal five-minute refresh, then shares display-ready values with WidgetKit. For consistent updates,
keep OpenUsage running; **Launch at Login** is the easiest way to do that.

When OpenUsage is closed, the widget keeps the last good values. It marks them **Outdated** after about
30 minutes. A provider refresh failure also keeps the last good values and shows a generic warning;
open the popover for the detailed error and recovery steps.

WidgetKit controls the exact moment a widget redraws, so a desktop widget can update later than the
five-minute in-app refresh. OpenUsage requests a redraw when provider values change, while WidgetKit
may combine background requests to stay within its system update budget. Reset countdowns continue
updating without another provider request.
