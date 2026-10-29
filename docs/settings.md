# Settings

Open Settings from the panel's **Options** menu or press **⌘,**. Every setting applies at once and
survives relaunch.

## General

| Setting | Control | What it changes |
|---|---|---|
| Launch at Login | switch | Registers OpenUsage as a login item, so it starts when you sign in to your Mac. |
| Global Shortcut | recorder | A keyboard shortcut that opens and closes the panel from any app. Click the field and press the keys. |

## Appearance

| Setting | Control | What it changes |
|---|---|---|
| Theme | System, Light, Dark | The panel's appearance. System follows macOS. |
| Time Format | Auto, 12-hour, 24-hour | How exact times read. Auto follows your macOS locale. |

## Usage display

| Setting | Control | What it changes |
|---|---|---|
| Show Usage As | Used, Left | Whether every bounded reading says `48% used` or `52% left`, on the dashboard and in the menu bar. A click on any bar row's value in the dashboard flips it too. |
| Reset Times | Countdown, Exact time | Whether reset labels read `Resets in 3h 25m` or `Resets today at 6:38 PM`. A click on any reset in the dashboard flips it too. |

## Notifications

Three independent triggers, all off by default. Turning the first one on asks macOS for notification
permission. While macOS has notifications off for OpenUsage, a footer under the switches says so and
links to System Settings.

| Setting | What it sends |
|---|---|
| Under 10% Remaining | The first time a metric with a limit drops under 10% left in its period. |
| Healthy Pace Changes | When a metric's pace worsens from on course to close to the limit. |
| Near-Limit Pace Changes | When a metric's pace worsens from close to the limit to running out. |

Each notification names the trigger, the provider, and the metric, and fires once per metric per reset window.

## Privacy

| Setting | Control | What it changes |
|---|---|---|
| Hide From Screen Share | switch | While your screen is shared or recorded, the menu bar shows the app icon instead of your usage. Off by default. See [Privacy](privacy.md). |
| Help Make OpenUsage Better | switch | Whether the app sends the optional daily provider-refresh summaries described in [Privacy](privacy.md). The anonymous daily active ping and crash reports do not depend on this switch. |

## Command Line

| Setting | Control | What it changes |
|---|---|---|
| Terminal Helper | Install…, Uninstall | Links `/usr/local/bin/openusage` to the `openusage` command inside the app, after the macOS administrator prompt, or removes that link. A link left by another copy of OpenUsage (an earlier version, or a build in another folder) is replaced on Install. Reads **Unavailable** when something OpenUsage did not install already sits at that path. See [Command line](cli.md). |

## Updates

This section appears in the released build only; the dev build has no update feed.

| Setting | Control | What it changes |
|---|---|---|
| Check Automatically | switch | Checks for a new version about once an hour and shows the **Update Available** banner on the dashboard when one is found. |
| Beta Updates | switch | Adds pre-release builds to the checks. Turn it off to stay on your current version until the next stable release. |
| Check for Updates… | button | Checks now and opens the update window. |

See [Updates](updates.md).

## Upgrading from 0.7.x

0.7.x found your accounts on its own, so you add them again on the Accounts screen. The exception is an
OpenRouter or Z.ai key you typed into 0.7.x, which it saved in `~/.config/openusage/openrouter.json` or
`~/.config/openusage/zai.json`. On the first launch after the update, OpenUsage adds each saved key as
an account when that provider has no account yet and a usage read accepts the key. It does this once,
so an account you remove later doesn't come back. If the usage read can't reach the provider, it tries
again on the next launch.

When you add the only account of a provider that was on in 0.7.x, it takes that provider's 0.7.x layout:

- **Stars.** It keeps the provider's 0.7.x stars on its metrics, or gets the default stars if none of
  those stars is on a metric it has.
- **Hidden metrics.** A metric that 0.7.x had and you turned off stays hidden. An account never starts
  with every metric hidden.
- **Metric order.** The metrics keep 0.7.x's order. Metrics that 0.7.x did not have go last.
- **Provider order.** The provider goes to its place in the provider order you saved in 0.7.x.

When 0.7.x showed several accounts of a provider, the one it showed first gives the layout. Any other
account of that provider starts with the default stars, as on a new install.

OpenUsage reads 0.7.x's layout and never changes it, and it deletes nothing that 0.7.x saved. If you go
back to 0.7.x, it finds its stars and order as you left them.
