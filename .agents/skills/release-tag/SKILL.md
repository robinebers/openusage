---
name: release-tag
description: >-
  Create a new release tag with version bump, generate a GitHub Release-style
  changelog, update CHANGELOG.md, and publish a GitHub Release. Use when the
  user asks to tag a release, bump the version, create a changelog, cut a
  release, or publish release notes.
---

# Release Tag

Bump the project version, generate a categorized changelog with author attribution, tag the release, and publish to GitHub Releases.

## Workflow

### 1. Determine New Version

- Read the current version from `package.json` and the latest git tag.
- Default bump type is **patch** (e.g. 0.1.0 → 0.1.1). The user may override with major or minor.
- Show the proposed new version and **confirm with the user** before proceeding.

### 2. Generate Changelog

Collect commits since the previous tag and build the changelog:

**Categorization rules:**

| Commit prefix | Category |
|---|---|
| `feat`, `feature`, or starts with "Add" | New Features |
| `fix` or starts with "Fix" | Bug Fixes |
| `refactor`, `enhance` | Refactor |
| `chore`, `style`, `docs`, `perf`, `test`, `ci`, `build` | Chores |
| Uncategorized | Bug Fixes |

**Author attribution (required on every entry):**

- Commits with a PR number (`(#123)`): `gh pr view {number} --json author -q '.author.login'`
- Commits without a PR number: `gh api /repos/{owner}/{repo}/commits/{full_hash} -q '.author.login'`
- If the API returns null, fall back to the git author name from `git log`.

**Output the changelog inside a markdown code block** using the template below so the user can review it.

### 3. User Approval

Wait for the user to explicitly approve the changelog before making any file changes. Accept edits if offered.

### 4. Update Version Files + CHANGELOG.md

Check for and update **every** version file that exists in the repo:

- `package.json`
- `src-tauri/tauri.conf.json`
- `src-tauri/Cargo.toml` (must update if tauri.conf.json exists)
- `Cargo.toml` (root-level, Rust projects)
- `pyproject.toml`
- `pubspec.yaml`
- `build.gradle` / `build.gradle.kts`
- `Info.plist` (`CFBundleShortVersionString`)

After updating any `Cargo.toml`, run `cargo update -p {package_name}` to sync `Cargo.lock`.

Prepend the approved changelog to `CHANGELOG.md` immediately after the `# Changelog` header. Create the file with that header if it does not exist.

Commit **all** changes (version bumps + CHANGELOG.md) in a single commit:

```
chore: bump version to {new_version}
```

### 5. Create Git Tag

```bash
git tag -a v{new_version} -m "v{new_version}"
```

### 6. Push Commit + Tag

Ask the user before pushing. If confirmed, push the commit and tag **before** creating the GitHub Release — `gh release create` resolves the tag on the remote, so the version bump commit must already be there.

```bash
git push origin {branch}
git push origin v{new_version}
```

### 7. Create GitHub Release

Do **not** create the release before the push — CI (e.g. tauri-action) may create its own release when it sees the tag. After the push, check whether the release already exists:

```bash
gh release view v{new_version} -R {owner}/{repo} 2>/dev/null
```

- If it **does not** exist: `gh release create v{new_version} --title "v{new_version}" --notes "{changelog}"`
- If it **already exists** (CI created it): `gh release edit v{new_version} --notes "{changelog}"` to add the release notes, then delete any leftover draft duplicates.

## Changelog Template

Only include category sections that have entries.

~~~markdown
## v{new_version}

### New Features
- {message} ([#{pr}](https://github.com/{owner}/{repo}/pull/{pr})) by @{author}

### Bug Fixes
- {message} ([#{pr}](https://github.com/{owner}/{repo}/pull/{pr})) by @{author}

### Refactor
- {message} ([#{pr}](https://github.com/{owner}/{repo}/pull/{pr})) by @{author}

### Chores
- {message} ([#{pr}](https://github.com/{owner}/{repo}/pull/{pr})) by @{author}

---

### Changelog

**Full Changelog**: [{prev_tag}...v{new_version}](https://github.com/{owner}/{repo}/compare/{prev_tag}...v{new_version})

- [{short_hash}](https://github.com/{owner}/{repo}/commit/{full_hash}) {commit message} by @{author}
~~~

## Rules

- Commit hashes in output are 7 characters (short hash).
- Tags are always prefixed with `v` (e.g. `v0.1.1`).
- Never push automatically -- always ask the user first.
- Always publish release notes to GitHub Releases -- never skip this step.
- For commits without a PR number, omit the PR link but still include the author.
