# OpenUsage documentation

What the app does and how it behaves. These pages describe behaviour, not visuals, and change together
with the behaviour they describe. If the app and a page here disagree, that is a bug.

## The app

- [Dashboard](dashboard.md): cards, accounts, metrics, right-click menus, reordering, keyboard shortcuts
- [Accounts](accounts.md): adding, renaming, and removing accounts; how sign-in works
- [CLIProxyAPI hubs](cliproxyapi.md): mirroring the Claude and ChatGPT logins of a CLIProxyAPI server
- [Menu bar](menu-bar.md): starring metrics into the menu bar
- [Settings](settings.md): every option and what it changes, and what carries over from 0.7.x
- [Command line](cli.md): the `openusage` command, its JSON output, and installing it
- [Refreshing](refreshing.md): when data updates and what happens when a fetch fails
- [Providers](providers.md): how each provider signs in and what it shows
- [Updates](updates.md): automatic updates, manual checks, and the beta channel
- [Proxy](proxy.md): sending provider requests through a SOCKS5, HTTP, or HTTPS proxy
- [Privacy](privacy.md): what stays on your Mac and what the anonymous telemetry sends

## For developers

- [Architecture](architecture.md): the composition root, the stores, the account runtime, the AppKit bridge
- [Adding a provider](adding-a-provider.md): the sign-in and usage contract, and the register, test, document steps
- [Debugging](debugging.md): running a local build and reading its logs
