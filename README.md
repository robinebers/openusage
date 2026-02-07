# OpenUsage

**Track all your AI coding subscriptions in one place.**

Cursor, Claude, Codex, and more coming. See your usage at a glance from your menu bar. No digging through dashboards.

![OpenUsage Screenshot](screenshot.png)

## Download

[**Download the latest release**](https://github.com/robinebers/openusage/releases/latest) (macOS, Apple Silicon & Intel)

The app auto-updates. Install once and you're set.

## What It Does

OpenUsage lives in your menu bar and shows you how much of your AI coding subscriptions you've used. Progress bars, badges, and clear labels. No mental math required.

- **One glance.** All your AI tools, one panel.
- **Always up-to-date.** Refreshes automatically on a schedule you pick.
- **Lightweight.** Opens instantly, stays out of your way.
- **Plugin-based.** New providers get added without updating the whole app.

## Supported Providers

- [**Cursor**](docs/providers/cursor.md) / plan, usage, on-demand
- [**Claude**](docs/providers/claude.md) / session, weekly, extra usage
- [**Codex**](docs/providers/codex.md) / session, weekly, code reviews, extra usage
- [**Copilot**](docs/providers/copilot.md) / usage tracking

### Coming Soon

- [Gemini](https://github.com/robinebers/openusage/issues/13) / [Antigravity](https://github.com/robinebers/openusage/issues/14)
- [Factory / Droid](https://github.com/robinebers/openusage/issues/16)
- [Windsurf](https://github.com/robinebers/openusage/issues/15)
- [Vercel AI Gateway](https://github.com/robinebers/openusage/issues/18)

Want a provider that's not listed? [Open an issue.](https://github.com/robinebers/openusage/issues/new)

## Open Source, Community Driven

OpenUsage is built by its users. Hundreds of people use it daily, and the project grows through community contributions: new providers, bug fixes, and ideas.

I maintain the project as a guide and quality gatekeeper, but this is your app as much as mine. If something is missing or broken, the best way to get it fixed is to contribute by opening an issue, or submitting a PR.

Plugins are currently bundled as we build our the API, but soon will be made flexible so you can build and load their own.

**Windows/Linux:** high-priority and on the todo, but I need testers with some time, willing to help out.

### How to Contribute

- **Add a provider.** Each one is just a plugin. See the [Plugin API](docs/plugins/api.md).
- **Fix a bug.** PRs welcome. Provide before/after screenshots.
- **Request a feature.** [Open an issue](https://github.com/robinebers/openusage/issues/new) and make your case.

Keep it simple. No feature creep, no AI-generated commit messages, test your changes.

## Sponsors

OpenUsage is supported by our sponsors. Become a sponsor to get your logo here and on [openusage.ai](https://openusage.ai).

[Become a Sponsor](https://github.com/sponsors/robinebers)

<!-- Add sponsor logos here -->

## Credits

Inspired by [CodexBar](https://github.com/steipete/CodexBar) by [@steipete](https://github.com/steipete). Same idea, very different approach.

## License

[MIT](LICENSE)

---

<details>
<summary><strong>Build from source</strong></summary>

### Stack

- Tauri 2 + Rust
- React 19, Tailwind 4, Base UI
- Vite 7, bun

### Build

```bash
git clone https://github.com/robinebers/openusage
cd openusage
bun install
bun tauri build
```

Built app lands in `src-tauri/target/release/bundle/`.

### Development

```bash
bun install
bun tauri dev
```

</details>
