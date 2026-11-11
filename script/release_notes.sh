#!/usr/bin/env bash
# Writes the body of the GitHub Release for <tag> to <out.md> for Sparkle's update window.
# generate_appcast --embed-release-notes embeds the file in the new appcast item as Markdown.
# The release-swift skill creates the release as a draft with the approved notes before it pushes the
# tag, so the body exists when release.yml runs. Fails when the release is missing or its body is empty,
# so an update never ships without notes.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <tag, e.g. v0.8.0> <out.md>" >&2; exit 2; }
tag="$1"
out="$2"

gh release view "$tag" --json body --jq .body > "$out" \
  || { echo "No GitHub Release for $tag. Create it as a draft with the approved notes before tagging." >&2; exit 1; }
grep -q '[^[:space:]]' "$out" || { echo "The GitHub Release for $tag has empty notes." >&2; exit 1; }
