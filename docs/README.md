# OpenUsage documentation

How the app behaves. If the app and a page here disagree, that is a bug.

## The app

- [Dashboard](dashboard.md): the Priority and All Usage tabs, right-click menus, reordering, shortcuts
- [Accounts](accounts.md): adding, renaming, and removing accounts, and how sign-in works
- [CLIProxyAPI hubs](cliproxyapi.md): the Claude, ChatGPT, Antigravity, Devin, and Grok logins of a
  CLIProxyAPI server
- [Menu bar](menu-bar.md): what the strip shows
- [Settings](settings.md): every option, and what carries over from 0.7.x
- [Command line](cli.md): the `openusage` command and its JSON output
- [Refreshing](refreshing.md): when data updates and what happens when a fetch fails
- [Providers](providers.md): how each provider signs in and what it shows
- [Updates](updates.md): automatic updates, manual checks, and the beta channel
- [Proxy](proxy.md): sending provider requests through a proxy
- [Privacy](privacy.md): what stays on your Mac and what the anonymous telemetry sends

## For developers

- [Architecture](architecture.md): the composition root, the stores, the account runtime, the AppKit bridge
- [Adding a provider](adding-a-provider.md): the sign-in and usage contract, and the steps to add one
- [Debugging](debugging.md): running a local build and reading its logs
