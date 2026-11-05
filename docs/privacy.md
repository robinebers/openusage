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

## Screen sharing

**Settings → Privacy → Hide From Screen Share** shows the app icon in the menu bar instead of your
usage while your screen is shared or recorded. It is off by default and doesn't hide the panel.

## Anonymous telemetry

| Data | When | Can you turn it off? |
| --- | --- | --- |
| App use ping | Once per local day | No |
| Crash reports | The launch after a crash | No |
| Provider account counts | Once per active install per local day | Yes |

- The **app use** ping says the app was active today, with the app and macOS version, which providers
  you have accounts for, and which metrics they have. Metric ids name the provider and metric
  (`claude.session`), never the account. A random install id lets the team count daily users.
- A **crash report** holds the stack trace of OpenUsage's own code and the app and macOS version. It
  holds no account details, credentials, or usage values.
- **Provider account counts** say how many accounts are configured for each provider, split between
  direct accounts and accounts imported from CLIProxyAPI. They use the same random install id as the
  app use ping and don't report refresh activity. Turn them off in **Settings → Privacy → Help Make
  OpenUsage Better**. They are on by default for new installs, and existing installs keep their
  stored choice.
- Telemetry never includes account names, emails, credentials, usage values, error messages, or file
  paths.
- OpenUsage never identifies you to the analytics service. The analytics choice and install id are
  stored apart from other settings, so an update never turns analytics back on or changes the id.
