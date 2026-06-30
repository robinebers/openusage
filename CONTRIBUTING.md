# Contributing to OpenUsage

OpenUsage accepts contributions through a strict, issue-first workflow, and the quality bar is deliberately high. **By design, most external pull requests are closed** — automation closes any that don't follow the rules below. Read this entire document before opening a PR.

## Philosophy

OpenUsage is highly opinionated. It focuses on clean design, fast performance, and a great user experience. The feature set is intentionally limited to core functionality: tracking AI coding subscription usage, nothing more. Contributions that try to expand that scope, add unnecessary complexity, or compromise the UX will be closed.

If you're unsure whether your idea fits, open an issue first. External pull requests without a linked, maintainer-approved issue are closed automatically — without review.

## Ground Rules

- **Open an approved issue first.** External PRs must link an open issue a maintainer has approved with the `approved` label. No approved issue, no review.
- **Most external PRs get closed, by design.** It's not personal — it keeps a small, focused project sane. See the Pull Request Policy below.
- No feature creep. If it's not about usage tracking, it doesn't belong here.
- No AI-generated commit messages. Write your own.
- Test your changes. If it touches UI, include before/after screenshots.
- Keep it simple. Don't over-engineer.
- One PR per concern. Don't bundle unrelated changes.
- Match the existing design language. OpenUsage has a specific look and feel — [AGENTS.md](AGENTS.md) documents the display conventions.

## Pull Request Policy

External pull requests are gatekept automatically and **closed** if they:

- **Have no approved issue** — they don't link an open issue labeled `approved`.
- **Are too large** — they change more than 1,000 lines. Split the work into smaller PRs.
- **Miss screenshots** — they make a visual change without before/after screenshots.

Closures aren't personal and are reversible: get the issue approved (or fix the problem), then reopen or open a focused replacement. Maintainers and collaborators may open PRs directly, and can override the automation with the `keep-open` label.

## License Agreement

By submitting a pull request, you agree that your contribution is licensed under the [MIT License](LICENSE) that covers this project.

## How to Contribute

### Fork and PR workflow

1. Open an issue describing the change, and wait for a maintainer to approve it with the `approved` label
2. Fork the repo
3. Create a branch (`feat/my-change`, `fix/some-bug`, etc.)
4. Make only the approved change
5. Run `swift build` and `swift test` to verify nothing is broken
6. Open a PR against `main` and link the approved issue with `Fixes #<issue>`

### Add a provider

Each provider is a small Swift module under `Sources/OpenUsage/Providers/<Name>/` that conforms to `ProviderRuntime`: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into metric lines. See [docs/adding-a-provider.md](docs/adding-a-provider.md) for the full walkthrough (and [docs/architecture.md](docs/architecture.md) for how the pieces fit together).

1. Open an issue and get it approved (`approved` label) — include why the provider fits and how its usage data is accessible
2. Create `Sources/OpenUsage/Providers/<Name>/` and implement `ProviderRuntime`
3. Register the provider in `AppContainer`
4. Add focused tests under `Tests/OpenUsageTests/`
5. Add a provider page in `docs/providers/` (metrics, credential sources, endpoints, troubleshooting)
6. Test it locally with `./script/build_and_run.sh`
7. Open a PR with screenshots showing it working

You can also [open an issue](https://github.com/robinebers/openusage/issues/new?template=new_provider.yml) to request a provider without building it yourself.

### Fix a bug

1. Reference the approved issue number in your PR
2. Describe the root cause and fix
3. Include before/after screenshots for UI bugs
4. Add a regression test if applicable

### Request a feature

Don't open a PR for a feature without an approved issue first. [Open an issue](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml), make your case, and wait for the `approved` label.

## What Gets Accepted

- Bug fixes with clear descriptions
- New providers that follow the existing provider architecture
- Documentation improvements
- Performance improvements with benchmarks
- Accessibility improvements

## What Gets Rejected

- External PRs without an approved issue (closed automatically)
- PRs over 1,000 lines, or that bundle unrelated changes
- Features that expand the scope beyond usage tracking
- Changes that compromise speed, simplicity, or the existing UX
- PRs without testing evidence
- Code with no clear purpose or explanation
- Cosmetic-only changes without prior discussion

## Code Standards

- Swift 6 with strict concurrency, built with SwiftPM (no Xcode project)
- Follow existing patterns in the codebase — [AGENTS.md](AGENTS.md) is the engineering contract
- User-visible behavior changes must update the matching `docs/` page(s) in the same PR
- UI copy is plain language and sentence case
- No new dependencies without justification

## Maintainers

- [@robinebers](https://github.com/robinebers) (lead)
- [@validatedev](https://github.com/validatedev)
- [@davidarny](https://github.com/davidarny)

All PRs require approval from at least 2 maintainers before merging.
Release tags (`v*`) are owner-managed and can only be created by [@robinebers](https://github.com/robinebers).

## Questions?

Open a [bug report](https://github.com/robinebers/openusage/issues/new?template=bug_report.yml) or [feature request](https://github.com/robinebers/openusage/issues/new?template=feature_request.yml) using the issue templates.
