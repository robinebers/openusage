---
name: release-swift
description: Cut a release of OpenUsage (Swift menu-bar app): pick a version, generate a categorized changelog, tag from `main`, and publish the GitHub Release with notes. Use to ship an Early Access beta or a stable release.
---

# Release Swift

Pushing a `v*` tag on `main` runs `.github/workflows/release.yml`, which builds, signs, notarizes, attaches `OpenUsage-<version>.dmg` to the GitHub Release, and updates the Sparkle `appcast.xml` on `gh-pages`. CI creates the release with an EMPTY body, so this skill generates the changelog, records it in `CHANGELOG.md`, and publishes the notes onto the release.

## Channels

- **Beta (Early Access):** suffixed tag like `v0.7.1-beta.1`. Marked a GitHub pre-release and added to Sparkle's `beta` channel. Only users with Early Access enabled get it; GitHub "Latest" is untouched.
- **Stable:** plain tag like `v0.7.1`. Marked non-prerelease, becomes GitHub "Latest", and ships to everyone.

The tag IS the version: `v0.7.1-beta.1` becomes `CFBundleShortVersionString = 0.7.1-beta.1`, and `CFBundleVersion` is the git commit count. There are no version files to bump.

## Cutting a release

### 1. Choose the version

Next number in the current lane (default bump: patch). Beta builds add a `-beta.N` suffix. Confirm with the owner before proceeding.

### 2. Generate the changelog

Collect commits since the **previous release in the same channel** and categorize each:

- **Stable cut:** span from the **last stable tag** to this one (e.g. `v0.7.0...v0.7.1`), so the notes roll up the entire beta series plus any post-beta commits. Never start a stable changelog at the last beta — that would omit every beta in the lane.
- **Beta cut:** span from the previous tag (the prior beta, or the last stable if it's the first beta in a lane) to this one.

| Commit prefix | Category |
|---|---|
| `feat`, `feature`, or starts with "Add" | New Features |
| `fix` or starts with "Fix" | Bug Fixes |
| `refactor`, `enhance` | Refactor |
| `chore`, `style`, `docs`, `perf`, `test`, `ci`, `build` | Chores |
| Uncategorized | Bug Fixes |

Author attribution (required on every entry):

- With a PR number `(#123)`: `gh pr view 123 --json author -q '.author.login'`.
- Without a PR number: `gh api /repos/robinebers/openusage/commits/{full_hash} -q '.author.login'`.
- If the API returns null, fall back to the git author name.

Output the changelog in a code block (template below) for review.

### 3. Owner approval

Wait for explicit approval of the changelog before changing any files. Accept edits if offered.

### 4. Record it in CHANGELOG.md

Prepend the approved section right after the `# Changelog` header. Commit on `main`:

```sh
git switch main && git pull
git add CHANGELOG.md && git commit -m "docs: changelog for v{version}"
```

### 5. Tag and push

```sh
git tag -a v{version} -m "v{version}"
git push origin main
git push origin v{version}
```

### 6. Publish the notes

CI creates the release with an empty body, so attach the approved notes after it finishes:

```sh
gh run watch
gh release view v{version} >/dev/null 2>&1   # confirm CI created the release
gh release edit v{version} --notes-file /tmp/notes-v{version}.md
```

Never leave a release blank.

### 7. Verify (never leave a draft)

```sh
gh release view v{version} --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
git fetch origin gh-pages && git show origin/gh-pages:appcast.xml | grep -F "OpenUsage-{version}.dmg"
curl -s "https://robinebers.github.io/openusage/appcast.xml" | grep -F "OpenUsage-{version}.dmg"
```

The second check matters: the `gh-pages` branch is deployed to the live site by the `Deploy Pages` workflow (defined on the `gh-pages` branch; the repo's Pages source is "GitHub Actions"). If the branch has the version but the live URL doesn't after ~10 minutes, re-run it with `gh workflow run deploy-pages.yml --ref gh-pages` — Sparkle clients only see the live URL.

Require `isDraft=false`, `isPrerelease=true` for beta or `false` for stable, an `OpenUsage-<version>.dmg` asset, `bodyLen>0`, and the version present in the appcast. If a draft was left behind, migrate its notes/assets onto the published release, then delete it — but only once a separate PUBLISHED release for the tag already exists:

```sh
tag="v{version}"
if [ "$(gh release view "$tag" --json isDraft --jq '.isDraft')" = "false" ]; then
  gh api repos/robinebers/openusage/releases --paginate \
    --jq '.[] | select(.draft and .tag_name=="'"$tag"'") | .id' \
    | xargs -I{} gh api -X DELETE repos/robinebers/openusage/releases/{}
else
  echo "No published release for $tag yet - publish it first; do NOT delete the draft."
fi
```

## Changelog template

Only include category sections that have entries.

~~~markdown
## v{version}

### New Features
- {message} ([#{pr}](https://github.com/robinebers/openusage/pull/{pr})) by @{author}

### Bug Fixes
- {message} ([#{pr}](https://github.com/robinebers/openusage/pull/{pr})) by @{author}

### Refactor
- {message} by @{author}

### Chores
- {message} by @{author}

---

### Changelog
**Full Changelog**: [{prev_tag}...v{version}](https://github.com/robinebers/openusage/compare/{prev_tag}...v{version})

- [{short_hash}](https://github.com/robinebers/openusage/commit/{full_hash}) {commit message} by @{author}
~~~

`{prev_tag}` is the previous release **in the same channel**: last stable for a stable cut, last beta (or last stable for the first beta in a lane) for a beta cut.

## Rules

- 7-char short commit hashes; tags always prefixed with `v`.
- Stable changelogs span last-stable → this-stable (roll up the whole beta series); beta changelogs span previous-tag → this-beta.
- Never push or tag automatically — ask the owner first.
- Always publish notes to the GitHub Release — never blank.
- The version is the tag; never edit version files.
- The appcast is append-only: older installs and the other channel's latest build must keep working, so the workflow aborts rather than shrink it.

Release secrets and one-time setup live in the README under [Release setup](../../../README.md#release-setup-one-time).
