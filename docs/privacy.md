# Privacy

OpenUsage reads nothing that belongs to other tools: no other app's Keychain items, auth files, logs,
databases, or environment variables. It holds only the credentials you add in the app, and it calls
only the provider APIs those accounts need.

## Credentials stored on this Mac

- OAuth tokens and API keys live in the app's own Keychain service
  (`com.robinebers.openusage.accounts`), one item per account. Removing an account deletes its item.
- A [CLIProxyAPI hub](cliproxyapi.md)'s management key lives in `com.robinebers.openusage.cliproxy-hubs`
  and is deleted with the hub. Hub accounts hold no token.
- Account names, the layout, settings, and the last fetched usage live in the app's preferences.
- Provider responses are never written to disk. Nothing syncs to iCloud.
- The [`openusage` command](cli.md) reads only that last fetched usage. It makes no network request
  and reads no Keychain item.
- A [proxy](proxy.md) password stays in your `~/.openusage/config.json`. OpenUsage reads it but never
  writes or logs it.

The [macOS widgets](macos-widgets.md) read a separate local copy of account names and display-ready
usage from an App Group shared with the app. That copy contains no credentials or detailed errors.
Removing an account removes its shared values too. Widget data never goes to the analytics service.

## Privacy Mode

**Settings → Advanced → Privacy → Privacy Mode** hides usage and account names from screenshots and recordings.
While your screen is shared or recorded, the menu bar shows the app icon instead of your usage and the
panel blurs account names. While it's on, copied usage pictures blur every account name; while it's
off, they leave email addresses out. It is off by default and doesn't hide macOS widgets. A single
still screenshot (⌘⇧3, ⌘⇧4) can't be detected, so use the copy button to share a picture.

## Anonymous telemetry

| Data | When | Can you turn it off? |
| --- | --- | --- |
| App use ping | Once per local day | No |
| Crash reports | The launch after a crash | No |
| Provider account counts | Once per active install per local day | Yes |

- The **app use** ping says the app was active today, with the app and macOS version, which providers
  you have accounts for, and which metrics they have. Metric ids name the provider and metric
  (`claude.session`), never the account. A random install id lets the team count daily users.
- A **crash report** holds the crash's reason text, the stack trace where it crashed, and the full file
  paths of the binaries on that stack. These usually include OpenUsage's own path, so when the app runs
  from inside your home folder (such as `~/Downloads`) a report can include your Mac user folder's name.
  It also holds the app and macOS version.
- **Provider account counts** say how many accounts are configured for each provider, split between
  direct accounts and accounts imported from CLIProxyAPI. They use the same random install id as the
  app use ping and don't report refresh activity. Turn them off in **Settings → Advanced → Privacy →
  Help Make OpenUsage Better**. They are on by default for new installs, and existing installs keep their
  stored choice.
- Every event above also carries what the analytics library adds on its own: the Mac model, the screen
  size and network reachability when known, your language, and your time zone.
- The app use ping and provider account counts never include account names, emails, credentials, usage
  values, error messages, or file paths. A crash report's reason text and file paths are sent as they
  are, so any name in them, such as a folder name, is sent too.
- OpenUsage never identifies you to the analytics service. The analytics choice and install id are
  stored apart from other settings, so an update never turns analytics back on or changes the id.
