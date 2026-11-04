#!/usr/bin/env bash
# Regenerate the prebuilt app icon committed at assets/AppIcon.prebuilt/.
#
# Why this exists: assets/AppIcon.icon uses the Icon Composer "refractivity" (Liquid Glass) feature.
# actool in every Xcode available on GitHub's macOS runners (26.4.1 and 26.5) crashes compiling it
# (Apple regression FB20183399 — 26.5 crashes even on an empty icon.json). Only older actool (e.g. the
# 26.2 on the maintainer's Mac) compiles it. So we compile it here on a capable machine, commit the
# output, and the release build copies it in instead of running actool.
#
# Run this on a Mac whose actool can read the .icon, then commit the updated assets/AppIcon.prebuilt/
# whenever the icon changes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/assets/AppIcon.prebuilt"

rm -rf "$OUT"
mkdir -p "$OUT"
# Re-commit the regenerated assets/AppIcon.prebuilt/ after running this (the maintainer runs it on a capable Mac).
xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$OUT" \
  --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings

echo "Wrote $OUT/Assets.car and AppIcon.icns"
