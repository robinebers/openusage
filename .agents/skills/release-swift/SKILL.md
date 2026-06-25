---
name: release-swift
description: Cut a release of the native Swift edition of OpenUsage (main branch + Sparkle): generate a categorized changelog, update CHANGELOG.md, tag, and publish the GitHub Release with notes. Use to ship a Swift build, an Early Access beta, or the public flip. Pairs with the frozen Tauri release history.
---

# Release Swift

Push a version tag on `main`; `.github/workflows/release.yml` builds, signs, notarizes, attaches `OpenUsage-<version>.dmg`, and updates the Sparkle `appcast.xml` on `gh-pages`. CI creates the GitHub Release but with an EMPTY body, so this skill also generates a categorized changelog, records it in `CHANGELOG.md`, and publishes those notes onto the release.

A tag with a pre-release suffix (e.g. `v0.7.0-beta.1`) publishes to the Early Access channel; a plain tag (`v0.7.0`) publishes to everyone.

## Guardrails (transition period)

- Swift owns version lane `0.7.x` and up. Never use a `0.6.x` number (Tauri's lane).
- Keep every Swift release a GitHub pre-release until the owner approves the public flip: push only `-beta.N` tags; `release.yml` marks any suffixed tag pre-release. Do NOT push a plain `vX.Y.Z` Swift tag during the transition because it intentionally becomes GitHub "Latest".
- Cut tags from a `main` commit so `release.yml` runs. The frozen Tauri edition remains on `tauri-legacy`.
- The version IS the tag: `vX.Y.Z` -> `CFBundleShortVersionString`; `CFBundleVersion` is the git commit count. There are NO version files to bump (unlike the Tauri skill).

## Cutting a release

### 1. Choose the version

Next number in the `0.7.x` lane (default bump: patch). Early Access builds use a `-beta.N` suffix. Confirm with the owner before proceeding.

### 2. Generate the changelog (commits since the previous tag)

Categorize each commit:

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

Output the changelog in a code block (template at the bottom) for review.

### 3. Owner approval

Wait for explicit approval of the changelog before changing any files. Accept edits if offered.

### 4. Record it in CHANGELOG.md (main branch)

Prepend the approved section right after the `# Changelog` header. Create `CHANGELOG.md` with that header on first use. Do NOT edit version files. Commit on `main`:

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

### 6. Publish the notes onto the GitHub Release

CI creates the release with an empty body, so attach the approved notes after it finishes (write them to a file first):

```sh
gh run watch
gh release view v{version} >/dev/null 2>&1   # confirm CI created the release
gh release edit v{version} --notes-file /tmp/notes-v{version}.md
```

Always publish the notes - never leave a Swift release blank. (The live `v0.7.0-beta.1` and `.2` shipped with empty descriptions; do not repeat that.)

### 7. Verify (mandatory - never leave a draft)

```sh
gh release view v{version} --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
git fetch origin gh-pages && git show origin/gh-pages:appcast.xml | grep -F "OpenUsage-{version}.dmg"
```

Require `isDraft=false`, `isPrerelease=true` (during the transition), an `OpenUsage-<version>.dmg` asset, `bodyLen>0`, and the version present in the appcast. If a draft was left behind, reconcile it (migrate any notes/assets the published release is missing), then delete it. Guard the delete so it can NEVER remove the sole release for a tag - it only runs once a separate PUBLISHED (non-draft) release for that tag already exists:

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

## The public flip (owner-approved only)

1. Confirm the final Tauri goodbye release `v0.6.28` already shipped and points users to the Swift download.
2. `git tag -a v0.7.0 -m "v0.7.0" && git push origin v0.7.0` - `release.yml` marks a plain tag non-prerelease, so it becomes GitHub "Latest".
3. Attach its notes (step 6).
4. Carry forward the final Tauri updater manifest onto the stable Swift GitHub Release. Older Tauri builds still fetch `releases/latest/download/latest.json`; once the Swift release becomes GitHub "Latest", this extra asset keeps those installs able to update to the `v0.6.28` migration-banner build:
   ```sh
   tmpdir="$(mktemp -d)"
   gh release download v0.6.28 --pattern latest.json --dir "$tmpdir"
   gh release upload v0.7.0 "$tmpdir/latest.json" --clobber
   ```
5. Verify the stable Swift release has its DMG, release notes, appcast entry, and the carried-forward `latest.json` asset.
6. Update openusage.ai + README to point at the Swift app.

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

## What ships

1. A Developer ID-signed, notarized `OpenUsage-<version>.dmg`, attached to the GitHub Release.
2. An updated `appcast.xml` published to the `gh-pages` branch and served from GitHub Pages (the feed
   URL baked into every build). `generate_appcast` signs the DMG and merges the new entry into the
   existing feed, preserving older versions and the other channel's latest build.

The pipeline lives in `.github/workflows/release.yml`. It builds and notarizes the DMG with
`script/release.sh`, then generates the appcast with Sparkle's official `generate_appcast` tool.

## Versioning

- The tag sets the human version as-is, including any pre-release suffix: `v0.7.0-beta.2` ->
  `CFBundleShortVersionString = 0.7.0-beta.2`. That same string appears in Sparkle's update prompt and
  in the app footer/About, so they always match. (Sparkle's docs use a beta short version too, e.g.
  `2.0b1`; Developer ID notarization does not require it to be numeric.)
- `CFBundleVersion` is the git commit count, which always increases. Sparkle compares it to decide
  whether a build is newer - not the short version string.

## One-time setup

### 1. Make the repository public

Sparkle downloads the DMG and the appcast without authentication. GitHub release assets and Pages are
only reachable anonymously on a public repo, so the repo must be public before the first real release.

### 2. Add the release secrets

Add these under repo Settings -> Secrets and variables -> Actions. They are all values you control as
the signing owner of the app:

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | base64 of your Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_ID` | the Apple ID email used for notarization |
| `APPLE_PASSWORD` | an app-specific password for that Apple ID |
| `APPLE_TEAM_ID` | your Apple Developer team ID |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key, baked into the build as `SUPublicEDKey` |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key used by `generate_appcast` to sign the DMG |

To create the certificate value: export your Developer ID Application cert (with its private key) from
Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. App-specific passwords are
created at appleid.apple.com under Sign-In and Security -> App-Specific Passwords. Generate the Sparkle
EdDSA key pair once with Sparkle's `generate_keys` tool and keep the private key backed up safely; the
public and private values must be a matching pair or `generate_appcast` will silently skip signing.

### 3. GitHub Pages

- The first release pushes the `gh-pages` branch with `appcast.xml`.
- Afterwards, in repo Settings -> Pages, confirm the source is the `gh-pages` branch. Auto-updates only
  need the feed URL to be live; the first build is downloaded by hand from the GitHub Release, and every
  later build can update automatically.

## Local dry run

Run the same build locally without uploading anything:

```sh
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)"
export SPARKLE_PUBLIC_KEY="<your base64 public key>"
export OPENUSAGE_VERSION="1.2.3"
export ALLOW_UNNOTARIZED=1   # skip notarization for a quick local check
./script/release.sh
```

To exercise notarization too, drop `ALLOW_UNNOTARIZED` and export `NOTARY_APPLE_ID`,
`NOTARY_APP_PASSWORD` (an app-specific password), and `NOTARY_TEAM_ID`. Without either path,
`script/release.sh` stops rather than produce an un-notarized build.

`script/release.sh` produces only the DMG in `dist/`. To build an appcast locally for testing, point
`generate_appcast` at a folder holding the DMG (it uses the Sparkle key in your keychain automatically):

```sh
GA=$(find .build/artifacts -name generate_appcast | head -n1)
mkdir -p feed && cp dist/OpenUsage-1.2.3.dmg feed/
"$GA" --download-url-prefix "https://github.com/<owner>/<repo>/releases/download/v1.2.3/" feed
cat feed/appcast.xml
```

For a pre-release, add `--channel beta`. `generate_appcast` only writes the `sparkle:edSignature` when
the DMG's embedded `SUPublicEDKey` matches the signing key, so use the same key pair throughout.

## Rules

- 7-char short commit hashes; tags always prefixed with `v`.
- Never push automatically - ask the owner first.
- Always publish notes to the GitHub Release - never blank.
- The version is the tag; never edit version files.
- Never commit secret values or private keys. They live only in GitHub Actions secrets and your local
  environment.
- The release feed is append-only on purpose: older installs and the other channel's items must keep
  working, so the workflow aborts rather than shrink the appcast.
- Tags are owner-managed. Only the project owner should create `v*` tags.
