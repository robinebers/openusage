#!/usr/bin/env bash
set -euo pipefail

WIDGET_BUILD_APPEX="${1:?Xcode-built widget app extension required}"
APP_BUNDLE="${2:?containing app bundle required}"
WIDGET_BUNDLE_ID="${3:?widget bundle identifier required}"
VERSION="${4:?bundle version required}"
BUILD="${5:?bundle build required}"
MIN_SYSTEM_VERSION="${6:?minimum system version required}"
ICON_NAME="${7:-AppIcon}"

WIDGET_NAME="OpenUsageWidgetExtension"
WIDGET_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$WIDGET_NAME.appex"
WIDGET_CONTENTS="$WIDGET_BUNDLE/Contents"
WIDGET_MACOS="$WIDGET_CONTENTS/MacOS"
WIDGET_RESOURCES="$WIDGET_CONTENTS/Resources"
WIDGET_INFO="$WIDGET_CONTENTS/Info.plist"

[ -d "$WIDGET_BUILD_APPEX" ] || { echo "missing Xcode-built widget extension: $WIDGET_BUILD_APPEX" >&2; exit 1; }
[ -x "$WIDGET_BUILD_APPEX/Contents/MacOS/$WIDGET_NAME" ] \
  || { echo "missing Xcode-built widget binary in: $WIDGET_BUILD_APPEX" >&2; exit 1; }

rm -rf "$WIDGET_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/PlugIns"
cp -R "$WIDGET_BUILD_APPEX" "$WIDGET_BUNDLE"
mkdir -p "$WIDGET_RESOURCES"

# WidgetKit presents the containing app's identity in the gallery. Carry the same compiled icon assets
# into the extension bundle too, matching Apple's extension guidance and keeping standalone bundle
# inspection honest.
for icon_asset in Assets.car "$ICON_NAME.icns"; do
  if [ -f "$APP_BUNDLE/Contents/Resources/$icon_asset" ]; then
    cp "$APP_BUNDLE/Contents/Resources/$icon_asset" "$WIDGET_RESOURCES/$icon_asset"
  fi
done

# Keep the processed Xcode Info.plist intact—the app-extension product type adds metadata that a
# hand-wrapped SwiftPM executable does not have. These replacements make the staging contract
# explicit even when callers override the project defaults.
plutil -replace CFBundleIdentifier -string "$WIDGET_BUNDLE_ID" "$WIDGET_INFO"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$WIDGET_INFO"
plutil -replace CFBundleVersion -string "$BUILD" "$WIDGET_INFO"
plutil -replace LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$WIDGET_INFO"
plutil -replace CFBundleIconName -string "$ICON_NAME" "$WIDGET_INFO"
plutil -lint "$WIDGET_INFO" >/dev/null
printf '%s\n' "$WIDGET_BUNDLE"
