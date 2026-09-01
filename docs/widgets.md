# Desktop Widgets

OpenUsage includes a macOS desktop widget for the metrics you have pinned to the menu bar. The widget
uses the same provider order, metric order, Used/Left setting, number formatting, and meter status as the
app, so there is no second widget-specific layout to maintain.

## Add the widget

1. Launch OpenUsage at least once after installing it.
2. Control-click the desktop and choose **Edit Widgets**.
3. Find OpenUsage and add the Usage Overview widget.
4. Choose a small, medium, large, or extra-large size.

Clicking the widget opens the OpenUsage dashboard. Development builds use a separate link from installed
release builds, so local testing does not open the wrong copy.

## Choose what appears

Open **Customize** in OpenUsage and star the metrics you want. Those menu-bar pins appear in the widget in
the same provider and metric order. The available space depends on the widget size:

- Small: 2 metrics
- Medium: 4 metrics
- Large: 8 metrics
- Extra Large: 12 metrics

When more metrics are pinned, the widget shows the first metrics that fit and reports how many remain.
Removing every pin gives the widget a prompt to add one in Customize.

## Updates and privacy

The menu-bar app fetches provider data and keeps the widget current. It asks macOS to reload the widget
when a pinned value or layout changes, with a five-minute timeline as a recovery path. If OpenUsage is not
running, the widget asks you to launch it; it does not read provider credentials or call provider APIs.

Widget values are marked as privacy-sensitive so macOS can redact them where the system's widget privacy
rules apply. When **Hide From Screen Share** is enabled and a capture is active, the widget replaces its
metrics with a Usage Hidden state alongside the menu-bar strip. Communication stays on `127.0.0.1`; no
credentials or tokens leave the app process.

## Building From Source

Use `script/build_and_run.sh` for local builds. It builds the app and CLI with SwiftPM, builds the widget
through `WidgetExtension/OpenUsageWidgetExtension.xcodeproj`, embeds the resulting `.appex`, signs the
nested components, and relaunches the app. The Xcode wrapper is required because WidgetKit must launch an
app-extension product; a plain SwiftPM executable renamed to `.appex` cannot provide widget descriptors.
