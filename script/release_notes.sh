#!/usr/bin/env bash
# Writes the CHANGELOG.md section under "## <heading>" to <out.md> for Sparkle's update window.
# generate_appcast --embed-release-notes embeds the file in the new appcast item as Markdown.
# Fails when the section is missing or empty, so an update never ships without notes.
# Reads CHANGELOG.md from the current directory, so the workflows can run this script from their own
# commit against an older checkout.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <heading, e.g. v0.8.0 or Unreleased> <out.md>" >&2; exit 2; }
heading="## $1"
out="$2"
changelog=CHANGELOG.md

grep -qxF "$heading" "$changelog" || { echo "CHANGELOG.md has no \"$heading\" section." >&2; exit 1; }
awk -v heading="$heading" '$0 == heading { found = 1; next } found && /^## / { exit } found' "$changelog" > "$out"
grep -q '[^[:space:]]' "$out" || { echo "CHANGELOG.md's \"$heading\" section is empty." >&2; exit 1; }
