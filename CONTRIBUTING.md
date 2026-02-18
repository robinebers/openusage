# Contributing to OpenUsage

OpenUsage accepts contributions, but has a high quality bar. Read this entire document before opening a PR.

## Philosophy

OpenUsage is highly opinionated. It focuses on clean design, fast performance, and a great user experience. The feature set is intentionally limited to core functionality: tracking AI coding subscription usage, nothing more. Contributions that try to expand that scope, add unnecessary complexity, or compromise the UX will be closed.

If you're unsure whether your idea fits, open an issue first.

## Ground Rules

- No feature creep. If it's not about usage tracking, it doesn't belong here.
- No AI-generated commit messages. Write your own.
- Test your changes. If it touches UI, include before/after screenshots.
- Keep it simple. Don't over-engineer.
- One PR per concern. Don't bundle unrelated changes.
- Match the existing design language. OpenUsage has a specific look and feel.

## License Agreement

By submitting a pull request, you agree that your contribution is licensed under the [MIT License](LICENSE) that covers this project.

## How to Contribute

### Fork and PR workflow

1. Fork the repo
2. Create a branch (`feat/my-change`, `fix/some-bug`, etc.)
3. Make your changes
4. Run `bun run build` and `bun run test` to verify nothing is broken
5. Open a PR against `main`

### Add a provider plugin

Each provider is a plugin. See the [Plugin API docs](docs/plugins/api.md) for the full spec.

1. Create a new folder under `plugins/` with your provider name
2. Add `plugin.json` (metadata) and `plugin.js` (implementation)
3. Add documentation in `docs/providers/`
4. Test it locally with `bun tauri dev`
5. Open a PR with screenshots showing it working

You can also [open an issue](https://github.com/robinebers/openusage/issues/new?template=new_provider.yml) to request a provider without building it yourself.

### Fix a bug

1. Reference the issue number in your PR
2. Describe the root cause and fix
3. Include before/after screenshots for UI bugs
4. Add a regression test if applicable

### Request a feature

Don't open a PR for large features without discussing first. [Open an issue](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml) and make your case.

## What Gets Accepted

- Bug fixes with clear descriptions
- New provider plugins that follow the Plugin API
- Documentation improvements
- Performance improvements with benchmarks
- Accessibility improvements

## What Gets Rejected

- Features that expand the scope beyond usage tracking
- Changes that compromise speed, simplicity, or the existing UX
- PRs without testing evidence
- Code with no clear purpose or explanation
- Cosmetic-only changes without prior discussion

## Code Standards

- TypeScript for frontend (`src/`)
- Rust for backend (`src-tauri/`)
- Follow existing patterns in the codebase
- No new dependencies without justification

## Maintainers

- [@robinebers](https://github.com/robinebers) (lead)
- [@validatedev](https://github.com/validatedev)
- [@davidarny](https://github.com/davidarny)

All PRs require approval from at least 2 maintainers before merging.
Release tags (`v*`) are owner-managed and can only be created by [@robinebers](https://github.com/robinebers).

## Questions?

Open a [bug report](https://github.com/robinebers/openusage/issues/new?template=bug_report.yml) or [feature request](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml) using the issue templates.
