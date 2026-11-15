#!/usr/bin/env bash
set -euo pipefail

# Prints the CFBundleVersion for release tag $1 (e.g. v0.8.0) built from HEAD.
#
# The build is the commit count. Sparkle compares installed copies by it, and generate_appcast keys
# appcast items by it. When an earlier release tag already shipped this commit (a beta promoted to
# stable), the count alone repeats that build: generate_appcast then merges the new DMG into the old
# item and keeps its channel, so a stable release stays on the beta channel (#1692). Each later
# release tag on the same commit adds a suffix instead: 888, then 888.1, then 888.2. Sparkle orders
# 888 < 888.1 < 889, so Early Access users move to the promoted build and the next commit still
# sorts higher. Earlier means created earlier, so a rerun of an older tag keeps its number.

TAG="${1:?usage: script/build_number.sh <tag, e.g. v0.8.0>}"
COUNT="$(git rev-list --count HEAD)"
EARLIER="$(git for-each-ref --points-at HEAD --sort=creatordate --format='%(refname:short)' 'refs/tags/v*' \
  | awk -v tag="$TAG" '$0 == tag { exit } { n++ } END { print n + 0 }')"

if [ "$EARLIER" -eq 0 ]; then
  echo "$COUNT"
else
  echo "$COUNT.$EARLIER"
fi
