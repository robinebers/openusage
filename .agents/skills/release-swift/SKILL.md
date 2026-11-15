---
name: release-swift
description: Cut a release of OpenUsage (Swift menu-bar app): pick a version, generate a categorized changelog, tag from `main`, and publish the GitHub Release with notes. Use to ship an Early Access beta or a stable release.
---

# Release Swift

Pushing a `v*` tag on `main` runs `.github/workflows/release.yml`, which builds, signs, notarizes, attaches `OpenUsage-<version>.dmg` to the GitHub Release, and updates the Sparkle `appcast.xml` on `gh-pages`. This skill generates the changelog and creates the GitHub Release as a draft with those notes before it pushes the tag. CI reads the notes from that release for Sparkle's update window, then publishes the same release with the DMG.

## Channels

- **Beta (Early Access):** suffixed tag like `v0.7.1-beta.1`. Marked a GitHub pre-release and added to Sparkle's `beta` channel. Only users with Early Access enabled get it; GitHub "Latest" is untouched.
- **Stable:** plain tag like `v0.7.1`. Marked non-prerelease, becomes GitHub "Latest", and ships to everyone.

The tag IS the version: `v0.7.1-beta.1` becomes `CFBundleShortVersionString = 0.7.1-beta.1`, and `CFBundleVersion` is the git commit count (`script/build_number.sh`). When a lower release tag already shipped the same commit, as when a beta is promoted to stable, the build gets a suffix: `888`, then `888.1`. Sparkle orders `888 < 888.1 < 889`, so the stable build is a new, higher build with its own appcast item. There are no version files to bump.

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

### 4. Create the draft release with the notes

Save the approved changelog to `/tmp/notes-v{version}.md` and create the release as a draft before tagging. Add `--prerelease` for a beta:

```sh
gh release create v{version} --draft --target main --title "OpenUsage {version}" --notes-file /tmp/notes-v{version}.md
```

`release.yml` reads this release's body as the notes in Sparkle's update window, before it builds anything, and fails the release when the release is missing or its body is empty. When it attaches the DMG, it publishes this draft instead of creating a new release. If you abandon the version, delete the draft before you push the tag. Once the tag is pushed, cancel the Release run and confirm it stopped (`gh run view <run-id>`) before you edit or delete the draft, or CI can publish a release with blank notes.

### 5. Tag and push

Before tagging, check that the commit's other release tags (if any) still leave this release a new build number. List them, compute the build CI will use, and check it against the live feed:

```sh
git switch main && git pull --tags
git tag --points-at HEAD 'v*'
build="$(script/build_number.sh v{version})" && echo "build $build"
curl -sf https://robinebers.github.io/openusage/appcast.xml \
  | python3 script/check_appcast.py preflight - v{version} "$build"
```

Require `Appcast OK`. An earlier tag on the commit is expected for a promoted beta; the build then has a suffix (for example `888.1`). Stop if the check fails: generate_appcast merges a DMG whose build the feed already has into the old item and keeps that item's channel and title, so a stable release would reach Early Access users only (#1692). CI runs the same check before it builds.

```sh
git tag -a v{version} -m "v{version}"
git push origin v{version}
```

### 6. Watch the run

```sh
gh run watch
```

CI publishes the draft with the DMG attached. If the run fails, the draft stays a draft: fix the cause and rerun the Release workflow for the tag.

### 7. Verify (never leave a draft)

```sh
gh release view v{version} --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
git fetch origin gh-pages && git show origin/gh-pages:appcast.xml | grep -F "OpenUsage-{version}.dmg"
curl -s "https://robinebers.github.io/openusage/appcast.xml" | grep -F "OpenUsage-{version}.dmg"
curl -sf "https://robinebers.github.io/openusage/appcast.xml" | python3 script/check_appcast.py verify - v{version}
```

The second check matters: publishing is two hops — Release pushes `appcast.xml` to the **`gh-pages` branch**, then **`.github/workflows/deploy-pages.yml` on `main`** deploys that branch to the live site (Pages source is "GitHub Actions", not legacy branch deploy). Auto deploy runs on `workflow_run` after Release completes; GitHub sometimes returns **"Deployment failed, try again later"** even though `gh-pages` is already correct. If the branch has the version but the live URL does not after ~10 minutes, check `gh run list --workflow=deploy-pages.yml` and re-run **`gh workflow run deploy-pages.yml --ref main`** (must use `main` — the workflow file is not on `gh-pages`). Sparkle clients only see the live URL.

Require `isDraft=false`, `isPrerelease=true` for beta or `false` for stable, an `OpenUsage-<version>.dmg` asset, `bodyLen>0`, and the version present in the appcast. The last command must print `Appcast OK`: for a stable version, the newest item without a `sparkle:channel` is this version; for a beta, the newest `beta` item is this version. Either way the item's title and `shortVersionString` are the version. If it fails, the feed needs a hand repair on `gh-pages`; ask the owner before you change it. If a draft was left behind, migrate its notes/assets onto the published release, then delete it — but only once a separate PUBLISHED release for the tag already exists:

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

## Test build (no release)

`.github/workflows/test-build.yml` builds the same signed, notarized DMG from any branch or commit without a tag, a release, or a feed update, so nobody is offered it. Run `gh workflow run test-build.yml --ref main -f ref=<branch-or-sha>`. It versions the build `<base_version>-test.<shortsha>` (default base `0.8.0-beta.1`) and uploads two artifacts: the DMG and a test `appcast.xml` that lists only that DMG at `http://localhost:8000/`.

- **Install test:** open the DMG and drag OpenUsage over the installed copy.
- **In-app update test:** put both artifacts in one folder, run `python3 -m http.server 8000` there, run `defaults write com.robinebers.openusage SUFeedURL http://localhost:8000/appcast.xml`, restart OpenUsage, and click **Check for Updates…**. Sparkle reads that user default before the built-in feed. Afterwards run `defaults delete com.robinebers.openusage SUFeedURL`, or the app keeps checking the test feed.

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
