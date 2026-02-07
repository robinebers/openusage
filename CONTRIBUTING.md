# Contributing to OpenUsage

OpenUsage accepts contributions, but has a high quality bar. Read this entire document before opening a PR.

## Ground Rules

- No feature creep. OpenUsage does one thing well: track AI coding subscription usage.
- No AI-generated commit messages. Write your own.
- Test your changes. If it touches UI, include before/after screenshots.
- Keep it simple. Don't over-engineer.
- One PR per concern. Don't bundle unrelated changes.

## DCO Sign-Off (Required)

All commits must include a `Signed-off-by` line (Developer Certificate of Origin).

This confirms you wrote the code and have the right to submit it. Add it with:

```bash
git commit -s -m "your commit message"
```

This appends a line like:

```
Signed-off-by: Your Name <your@email.com>
```

PRs without sign-off will be blocked by CI. If you forget, amend:

```bash
git commit --amend -s
git push --force
```

## How to Contribute

### Fork and PR workflow

1. Fork the repo
2. Create a branch (`feat/my-change`, `fix/some-bug`, etc.)
3. Make your changes
4. Run `bun run build` and `bun run test` to verify nothing is broken
5. Commit with sign-off (`git commit -s`)
6. Open a PR against `main`

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
- PRs without DCO sign-off
- PRs without testing evidence
- Code with no clear purpose or explanation
- Cosmetic-only changes without prior discussion

## Code Standards

- TypeScript for frontend (`src/`)
- Rust for backend (`src-tauri/`)
- Follow existing patterns in the codebase
- No new dependencies without justification

## Questions?

Open a [bug report](https://github.com/robinebers/openusage/issues/new?template=bug_report.yml) or [feature request](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml) using the issue templates.
