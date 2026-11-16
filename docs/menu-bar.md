# Menu bar

The menu bar can show a classic provider strip or just the limits needing attention.

- Left-click the icon to open the panel. Right-click (or control-click) it for **Settings** and
  **Quit OpenUsage**.
- Enable **Settings → Display → Always Show In Menu Bar** for the classic 0.7.4 text layout:
  one provider icon beside one large value or two stacked values, including healthy limits.
- The classic strip follows your saved provider and metric order. It uses the 0.7.4 default metrics
  where available (usually Session and Weekly), otherwise the first two reported metrics. Pin metrics
  in the dashboard to select a different pair for that account. Up to two reported pins show;
  missing readings are skipped. Values follow **Show Usage As**, including percent left.
- **Max Items In Menu Bar** limits provider icons in the classic strip. Additional providers show
  as a count, like `+7`. Multiple accounts keep their own icons and initials unless unified.
- With Always Show off (the default), only limits running out show, most urgent first. The maximum
  counts individual limits in this mode, each with a short label and value; remaining running-out
  limits show as a count. Used Up limits do not show or count in this mode.
- With nothing to show, or with **App Icon Only**, the strip shows the app icon.
- With [Privacy Mode](privacy.md#privacy-mode) on, it shows the app icon while your screen
  is shared or recorded.
- When an [update](updates.md) is available, the app icon shows at the end of the strip until the
  update banner goes away.
- When a provider has more than one account, its mark carries the account name's initials: "Personal"
  reads P and "Attention Machine 1" reads A1. Rename one of two accounts with the same initials to tell
  them apart. A provider with [Unify Multiple Accounts](dashboard.md#unify-multiple-accounts) on shows
  each limit once, with no initials.
