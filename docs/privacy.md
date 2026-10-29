# Privacy

OpenUsage reads nothing that belongs to other tools. It never opens another app's Keychain items,
auth files, logs, databases, or environment variables. The only credentials it holds are the ones you
create by adding an account in the app, and the only network requests it makes for usage are the
provider API calls those accounts need.

## Credentials stored on this Mac

OAuth tokens and API keys live in the app's own Keychain service (`com.robinebers.openusage.accounts`),
one item per account. Removing an account deletes its item. Account names, the layout, settings, and
the last fetched usage live in the app's own preferences. Nothing is synced to iCloud. The
[`openusage` command](cli.md) reads that last fetched usage and nothing else: no Keychain item, no
network request. A [proxy](proxy.md) user name and password stay in your own
`~/.openusage/config.json`, which OpenUsage reads but never writes or logs.

The [macOS widgets](macos-widgets.md) read a separate local copy of account names and display-ready
usage from an App Group shared with the app. That copy contains no credentials or detailed errors.
Removing an account removes its shared values too. Widget data never goes to the analytics service.

## Screen sharing

With **Settings → Privacy → Hide From Screen Share** on, the menu bar shows the app icon instead of
your usage while your screen is shared or recorded. It is off by default and does not hide the panel
or macOS widgets. To tell that a capture is running, OpenUsage asks the macOS window server whether
anything is watching the screen.

## Anonymous telemetry

OpenUsage always sends an anonymous daily active ping and anonymous crash reports so the team can count
active users and fix crashes. These are not optional.

You can also share extra anonymous usage analytics. Extra analytics is on by default for new installs.
Turn it off any time in **Settings → Privacy → Help Make OpenUsage Better**. Existing installs keep
the choice they already stored.

### What is always shared

- Once per local day, an **app use** ping: that the app was active today, the app and macOS version,
  which providers you have accounts for, which metrics are shown, and which are starred in the menu
  bar. Metric ids name the provider and the metric (`claude.session`), never the account. A random
  install id, not tied to you or any account, lets the team count daily active users.
- **Crash reports**: if OpenUsage crashes, it saves a report and sends it the next time it starts. The
  report holds the stack trace of OpenUsage's own code and the app and macOS version. It holds no
  account details, credentials, or usage values.

### What the toggle shares

With extra analytics on, OpenUsage sends at most one event per provider per day with how many
refreshes succeeded or failed and how many manual refreshes you triggered.

### What is never shared

- No account names, emails, or credentials.
- No usage values: no limits, balances, or spend.
- No error messages or file paths, only success and failure counts.

### How it works

- Data is anonymous: OpenUsage never identifies you to the analytics service and creates no user profile.
- Counts are rolled up locally and sent as daily summaries, so the 5-minute refresh never turns into a
  flood of network calls.
- Your analytics choice and the install id are stored apart from the rest of the settings, so an app
  update never re-enables extra analytics or changes the id.
