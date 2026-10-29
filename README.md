# OpenUsage

Track your AI coding subscriptions from the macOS menu bar.

OpenUsage shows how much of each AI plan you have used: session and weekly limits, credits, and
balances, in one panel. Star the metrics you watch most and they appear in the menu bar.

You add each account in the app. OpenUsage reads nothing that belongs to other tools: no Keychain
items, auth files, logs, databases, or environment variables. It shows only the limits and dollar
values that the provider's own API reports, except ChatGPT's credits, which also show their dollar
value at 4¢ a credit.

<!-- assets/screenshot.jpg needs a new capture of the account-based dashboard before release. -->
<p align="center">
  <img src="assets/screenshot.jpg" alt="OpenUsage menu bar panel showing Claude and ChatGPT usage limits" width="900">
</p>

## Installation

**Homebrew:**

```sh
brew install --cask openusage
```

**Direct download:** download the latest universal DMG from the
[releases page](https://github.com/robinebers/openusage/releases/latest), open it, and drag OpenUsage
to your Applications folder.

Either way, the app updates itself in place through signed, notarized
[Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

## Accounts

Open **Accounts** from the panel's **Options** menu (or press Return), click **+**, and click a
provider to start its sign-in. Browser sign-in opens your browser; **Open Browser** opens it again and
**Copy Link** lets you pick another browser. Device-code sign-in shows the code to enter. API-key
sign-in links to the page where you create the key. You can add several accounts for the same provider. See
[Accounts](docs/accounts.md) for renaming and removing accounts.

Account names and settings live in the app's own preferences. OAuth tokens and API keys live in the
app's own Keychain service.

## Providers

Claude, ChatGPT, Cursor, Antigravity, Copilot, Grok, Ollama, OpenCode, OpenRouter, and Z.ai. Claude,
ChatGPT, Cursor, Antigravity, Copilot, and Grok sign in with OAuth. Ollama, OpenCode, OpenRouter, and
Z.ai use API keys. OpenRouter's balance needs a Management key. [Providers](docs/providers.md) lists
what each one shows and what each sign-in grants.

## Features

- **Menu bar stars.** Star up to two metrics per provider. When more than one account of a provider is
  starred, each mark carries the account name's initials.
- **Dashboard.** A header and a card per provider. The header shows the provider's logo and name, and
  inside the card every account, even when it is the only one, has a caption with its name and plan
  above its rows. One row per metric: label, bar, value, and reset. With a reset window the bar's colour is where your pace lands at the
  reset: blue on course, orange inside the last 10%, red with a flame before the value when you would
  run out first; without one, blue, orange once 75% is used, red once 90% is. Click a value to flip
  every row between used and left, a reset between countdown and exact time. Rest the pointer on a bar
  to read where your pace lands at the reset, on a value to read its other side, on a reset to read
  the other format, and on the warning or clock after an account's name to read why it is there.
  Right-click a header, a card, an account, or a row for its actions. Drag to reorder.
- **Resets.** Claude and ChatGPT accounts show a Limit Resets row with the number of available rate-limit
  resets. Rest the pointer on the count to see when each expires, and spend one from there.
- **Share.** Rest the pointer on a provider's header and click the copy button at its right, or
  right-click the provider and choose Share Screenshot, to copy a PNG of its header and card, with
  every account, to the clipboard; from an account's right-click, that account alone. The picture uses
  the account's name when you have set one and leaves an email out.
- **Notifications.** Optional alerts when a limit falls under 10% or your pace changes.
- **Global shortcut.** Toggle the panel from anywhere.
- **[Command line](docs/cli.md).** Install the `openusage` command from Settings; it prints the usage
  the app last fetched as JSON, for scripts and agents.
- **[Automatic updates](docs/updates.md).** Signed, notarized in-app updates, with an optional beta
  channel.
- **[Proxy](docs/proxy.md).** Send provider requests through a SOCKS5, HTTP, or HTTPS proxy set in
  `~/.openusage/config.json`.

## Documentation

Behaviour docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md),
[accounts](docs/accounts.md), the [menu bar](docs/menu-bar.md), [settings](docs/settings.md),
the [command line](docs/cli.md), [refreshing](docs/refreshing.md), [providers](docs/providers.md),
[updates](docs/updates.md), the [proxy](docs/proxy.md), and [privacy](docs/privacy.md).

For working on the code, see [architecture](docs/architecture.md),
[adding a provider](docs/adding-a-provider.md), and [debugging](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary, for Apple Silicon and Intel Macs

## Building

```sh
swift build                 # debug build
script/test_quiet.sh        # run the test suite without it taking the keyboard or the screen
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```

`script/test_quiet.sh` takes `swift test` arguments such as `--filter`.

The dev app is staged as `dist/OpenUsage.app` with the bundle identifier
`com.robinebers.openusage.dev`, so it runs beside an installed OpenUsage and never checks for updates.

## Architecture

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` and a key-capable
`NSPanel`, Swift 6 strict concurrency. `AccountStore` persists accounts, `CredentialVault` stores
their credentials, `ProviderLogin` signs in, and one `AccountProviderRuntime` per account fetches
usage and maps it to metric lines. See the [architecture overview](docs/architecture.md) and
[AGENTS.md](AGENTS.md) for conventions.

## Releasing

Releases are automated: pushing a `v*` tag on `main` builds, signs, notarizes, and publishes a new
version. A plain tag (`v0.8.0`) ships to everyone; a pre-release suffix (`v0.8.0-beta.1`) ships to
the beta channel. The pipeline lives in
[.github/workflows/release.yml](.github/workflows/release.yml), and the step-by-step is in the
`release-swift` skill.

### Release setup (one-time)

The release workflow needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret                       | What it is                                                            |
| ---------------------------- | --------------------------------------------------------------------- |
| `APPLE_CERTIFICATE`          | base64 of your Developer ID Application `.p12`                        |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12`                           |
| `APPLE_ID`                   | the Apple ID email used for notarization                              |
| `APPLE_PASSWORD`             | an app-specific password for that Apple ID                            |
| `APPLE_TEAM_ID`              | your Apple Developer team ID                                          |
| `SPARKLE_PUBLIC_KEY`         | base64 EdDSA public key, baked into the build as `SUPublicEDKey`      |
| `SPARKLE_PRIVATE_KEY`        | base64 EdDSA private key used to sign the DMG                         |
| `POSTHOG_CLI_API_KEY`        | PostHog personal API key used to upload dSYMs for crash symbolication |
| `POSTHOG_CLI_PROJECT_ID`     | numeric PostHog project ID the dSYMs upload to                        |

Export the Developer ID Application cert (with its private key) from Keychain Access as a `.p12`,
then `base64 -i DeveloperID.p12 | pbcopy`. App-specific passwords come from appleid.apple.com →
Sign-In and Security → App-Specific Passwords. Generate the Sparkle EdDSA key pair once with Sparkle's
`generate_keys` tool; the public and private values must be a matching pair or signing is silently
skipped.

The two `POSTHOG_CLI_*` secrets only upload debug symbols (dSYMs) so PostHog can symbolicate crash
reports. `POSTHOG_CLI_API_KEY` is a PostHog personal API key (PostHog → Settings → Personal API keys)
and `POSTHOG_CLI_PROJECT_ID` is the numeric ID from your project URL. The upload host is hardcoded in
the workflow (`https://us.i.posthog.com`). These two do not block a release: if `POSTHOG_CLI_API_KEY`
is unset the workflow skips the upload with a warning, and crash reports for that version show raw
addresses instead of symbolicated stack traces.

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the appcast is
served from GitHub Pages. Confirm Settings → Pages points at the `gh-pages` branch after the first
release.

## Contributing

Issues are welcome. Pull requests are **strict and issue-first**: comment on an issue, wait for a
maintainer to add the `approved` label and assign it to you, then reference it in your PR with
`Fixes #123`. Automation closes external PRs without an approved issue assigned to their author, and
warns when an accepted PR adds more than 1,000 lines. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening one. Report security issues privately per [SECURITY.md](SECURITY.md). The OpenUsage name and
logo are covered by the [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
