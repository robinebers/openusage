#!/usr/bin/env bash
# Regenerate a prebuilt app icon. Run without arguments for the release icon, or with `dev` for the
# solid-black development icon committed at assets/AppIconDev.prebuilt/.
#
# Why this exists: assets/AppIcon.icon uses the Icon Composer "refractivity" (Liquid Glass) feature.
# actool in every Xcode available on GitHub's macOS runners (26.4.1 and 26.5) crashes compiling it
# (Apple regression FB20183399 — 26.5 crashes even on an empty icon.json). Only older actool (e.g. the
# 26.2 on the maintainer's Mac) compiles it. So we compile it here on a capable machine, commit the
# output, and the release build copies it in instead of running actool.
#
# Run this on a Mac whose actool can read the .icon, then commit the matching prebuilt directory
# whenever either icon changes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${1:-release}"

case "$VARIANT" in
  release)
    ICON_NAME="AppIcon"
    ;;
  dev)
    ICON_NAME="AppIconDev"
    ;;
  *)
    echo "usage: $0 [release|dev]" >&2
    exit 2
    ;;
esac

OUT="$ROOT_DIR/assets/$ICON_NAME.prebuilt"

rm -rf "$OUT"
mkdir -p "$OUT"
# Re-commit the regenerated prebuilt directory after running this on a capable Mac.
xcrun actool "$ROOT_DIR/assets/$ICON_NAME.icon" --compile "$OUT" \
  --app-icon "$ICON_NAME" --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings
rm -f "$OUT/partial.plist"

echo "Wrote $OUT/Assets.car and $ICON_NAME.icns"
