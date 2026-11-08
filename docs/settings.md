# Settings

Open Settings from the panel's **⋯** menu or press **⌘,**. It has four tabs: General, Display,
Alerts, and Advanced. Changes apply at once. Hover the ⓘ beside a setting to see what it does.

## General

- **Launch at Login.** Starts OpenUsage when you sign in to your Mac.
- **Default Tab.** Priority or All Usage, the tab the panel opens to.
- **Global Shortcut.** Opens and closes the panel from any app. Click the field and press the keys.

## Priority

- **Max Items In Menu Bar.** App Icon Only, or Up to 1 through Up to 5 limits, closest to running out
  first. Others show as a count, like `+7`. The default is Up to 3. See [Menu bar](menu-bar.md).
- **Always Show In Menu Bar.** The menu bar lists everything Priority does, in its order: Pinned,
  Running Out, Use It or Lose It, then Used Up. Off by default, showing only what's running out.
- **Warning.** A limit with this much left or less turns orange and moves to Running Out. 20% to
  70% left, 30% by default.
- **Critical.** A limit with this much left or less turns red. 5% to 25% left, 10% by default.
- **Burning Fast.** Also lists a limit under Running Out, and in the menu bar, when it would run out
  before it resets at your current pace, however much it has left. On by default.
- **Use It or Lose It.** Lists a limit in its own Priority section when it resets within 24 hours
  with over 50% left, the same rule as the alert of that name. It shows in the menu bar only with
  Always Show In Menu Bar on. On by default, and separate from the alert.

Warning and Critical always count what's left, even with Show Usage As set to Used, and they also
pick which limits the menu bar shows and when the Warning and Critical notifications fire. Critical
always stays under Warning: moving one onto the other pushes the other 5% along.

## Appearance

- **Theme.** System, Light, or Dark.
- **Time Format.** Auto (your macOS locale), 12-hour, or 24-hour.

## Usage display

- **Show Usage As.** `48% used` or `52% left`, on the dashboard and in the menu bar.
- **Reset Times.** `Resets 3h 25m` or `Resets Wed 4:00 PM`.
- **Pace Marks.** A tick on each bar and Priority ring where usage would be at an even pace through
  the window. Off by default.

Click a limit's amount or reset on the dashboard to flip either one.

## Notifications

All off by default. Turning the first one on asks macOS for permission.
If notifications are off for OpenUsage, click **System Settings** in the notice to open
**Notifications → OpenUsage** and allow them.

- **Critical.** A limit drops to its Critical level or less left (10% by default).
- **Warning.** A limit drops to its Warning level or less left (30% by default).
- **Will Run Out.** A limit may run out before its reset. After it fires, it waits until the limit's
  pace eases to 90% of the limit before it can fire again.
- **Use It or Lose It.** A limit resets within 24 hours with over 50% left. Only for windows longer
  than a day, such as weekly and monthly limits, never the 5-hour session or a dollar spending cap.

Each fires once per metric per reset window. Click one to open All Usage.

## Privacy

- **Privacy Mode.** Shows the app icon instead of your usage, and blurs account names in the panel,
  while your screen is shared or recorded. Copied pictures blur account names while it's on. Off by
  default.
- **Help Make OpenUsage Better.** Sends optional daily account counts by provider. The daily active
  ping and crash reports don't depend on it.

See [Privacy](privacy.md).

## Command line

- **Terminal Helper.** **Install…** links `/usr/local/bin/openusage` to the app's `openusage`
  command, after a macOS administrator prompt. **Uninstall** removes the link. It reads
  **Unavailable** when something OpenUsage didn't install sits at that path. See
  [Command line](cli.md).

## Debug

- **Log Level.** Error, Warning, Info (default), or Debug. Choose Debug while you reproduce a
  problem. See [Debugging](debugging.md).

## Updates

- **Check Automatically.** Checks about once an hour and shows **Update Available** on the
  dashboard.
- **Beta Updates.** Includes pre-release builds.
- **Check for Updates…** checks now.

The dev build disables these. See [Updates](updates.md).

## Upgrading from 0.7.x

0.7.x found your accounts on its own. Add them again on the Accounts screen.

- **Saved keys.** On the first launch after the update, OpenUsage adds an OpenRouter or Z.ai key
  that 0.7.x saved in `~/.config/openusage/openrouter.json` or `~/.config/openusage/zai.json`. It
  does this only if the provider has no account yet, 0.7.x had it on, and a usage read accepts the
  key. It never reads a key for a provider you turned off. A rejected key isn't tried again. Other
  failures retry on the next launch. An account you remove later doesn't come back.
- **Layout.** When you add the only account of a provider that was on in 0.7.x, it takes 0.7.x's
  hidden metrics, metric order, and provider order. New metrics start shown and go last. Stars don't
  carry over: the menu bar picks its own limits.
- **Going back.** OpenUsage never changes or deletes what 0.7.x saved.
