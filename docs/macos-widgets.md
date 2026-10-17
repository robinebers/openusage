# macOS Widgets

OpenUsage includes a native macOS widget for the desktop and Notification Center. Each widget instance
shows one provider; add more instances to keep several providers visible.

## Add and configure one

1. Launch OpenUsage at least once so it can publish the first usage snapshot.
2. Open the macOS widget gallery and add **Provider Usage**.
3. Edit the widget to choose a provider. The list suggests the providers you have on, and covers every
   provider OpenUsage shows, including extra Claude or Codex accounts.
4. Choose the small, medium, or large size.

The widget follows the provider's enabled metrics and saved order in OpenUsage. Small and medium focus
on the metrics shown above the provider's expand caret; large widgets can also include metrics marked
"Shown on expand." Usage Trend charts stay in the popover.

Clicking a widget opens the OpenUsage popover at that provider. If the provider is off or has no enabled
widget-compatible metrics (for example, only Usage Trend remains), it opens the provider's Customize
screen instead. If the widget has no provider to open or the chosen provider is no longer available,
clicking it opens the dashboard so you can recover there.
On a first launch, complete or skip the welcome screen first; OpenUsage then opens the widget's
destination.

## Updates and stale data

The widget never reads credentials or contacts providers itself. OpenUsage remains responsible for its
normal five-minute refresh, then shares display-ready values with WidgetKit. For consistent updates,
keep OpenUsage running; **Launch at Login** is the easiest way to do that.

When OpenUsage is closed, the widget keeps the last good values. It marks them **Outdated** after about
30 minutes. A provider refresh failure also keeps the last good values and shows a generic warning;
open the popover for the detailed error and recovery steps.

If the chosen provider disappears from OpenUsage (for example, you sign out of a second account), the
widget says **Provider Unavailable** instead of switching to a different provider.

If the shared data cannot be read, the widget shows **Unable to Read Data**. If it requires a newer
widget version, it shows **Update Required**. These messages also appear before a provider is selected.

WidgetKit controls the exact moment a widget redraws, so a desktop widget can update later than the
five-minute in-app refresh. OpenUsage requests a redraw when provider values change, while WidgetKit
may combine background requests to stay within its system update budget. Reset countdowns continue
updating without another provider request.
