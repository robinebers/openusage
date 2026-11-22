#!/usr/bin/env bash
set -euo pipefail

# Prints the CFBundleVersion for release tag $1 (e.g. v0.8.0) built from HEAD.
#
# The build is the commit count. Sparkle compares installed copies by it, and generate_appcast keys
# appcast items by it. When a lower release tag already sits on this commit (a beta promoted to
# stable), the count alone repeats that build: generate_appcast then merges the new DMG into the old
# item and keeps its channel, so a stable release stays on the beta channel (#1692). Each higher
# release tag on the same commit adds a suffix instead: 888, then 888.1, then 888.2. Sparkle orders
# 888 < 888.1 < 889, so Early Access users move to the promoted build and the next commit still
# sorts higher. Tags rank by version (0.8.0-beta.8 < 0.8.0), so the answer is the same before and
# after the tag exists and for annotated and lightweight tags.

TAG="${1:?usage: script/build_number.sh <tag, e.g. v0.8.0>}"
COUNT="$(git rev-list --count HEAD)"
LOWER="$({ git tag --points-at HEAD 'v*' | grep -vxF "$TAG" || true; echo "$TAG"; } | awk '
  {
    core = $0; sub(/^v/, "", core); pre = ""
    if (index(core, "-")) { pre = substr(core, index(core, "-") + 1); core = substr(core, 1, index(core, "-") - 1) }
    split(core, v, "."); label = pre; num = 0
    if (match(pre, /[0-9]+$/)) { label = substr(pre, 1, RSTART - 1); num = substr(pre, RSTART) }
    printf "%09d.%09d.%09d.%d.%s.%09d %s\n", v[1], v[2], v[3], (pre == ""), label, num, $0
  }' | LC_ALL=C sort | awk -v tag="$TAG" '$2 == tag { print NR - 1 }')"

if [ "$LOWER" -eq 0 ]; then
  echo "$COUNT"
else
  echo "$COUNT.$LOWER"
fi
