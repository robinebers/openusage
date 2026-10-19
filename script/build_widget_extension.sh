#!/usr/bin/env bash
set -euo pipefail

# Builds the WidgetKit extension without signing and embeds it in an already-staged OpenUsage.app.
# The containing build script owns identities and signs the nested .appex before sealing the app.
#
# Required env:
#   APP_BUNDLE, WIDGET_BUNDLE_ID, OPENUSAGE_APP_GROUP, OPENUSAGE_URL_SCHEME
#   WIDGET_VERSION, WIDGET_BUILD, WIDGET_ARCHS (space-separated, e.g. "arm64 x86_64")
# Optional env:
#   WIDGET_CONFIGURATION (Debug/Release; default Release)
#   OPENUSAGE_TEAM_ID (used for build-setting expansion; defaults to empty)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${APP_BUNDLE:?set APP_BUNDLE to the staged OpenUsage.app}"
: "${WIDGET_BUNDLE_ID:?set WIDGET_BUNDLE_ID}"
: "${OPENUSAGE_APP_GROUP:?set OPENUSAGE_APP_GROUP}"
: "${OPENUSAGE_URL_SCHEME:?set OPENUSAGE_URL_SCHEME}"
: "${WIDGET_VERSION:?set WIDGET_VERSION}"
: "${WIDGET_BUILD:?set WIDGET_BUILD}"
: "${WIDGET_ARCHS:?set WIDGET_ARCHS}"

CONFIGURATION="${WIDGET_CONFIGURATION:-Release}"
CONFIGURATION_KEY="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
DERIVED_DATA="$ROOT_DIR/.build/widget-derived-$CONFIGURATION_KEY"
PRODUCT="$DERIVED_DATA/Build/Products/$CONFIGURATION/OpenUsageWidgets.appex"
DESTINATION="$APP_BUNDLE/Contents/PlugIns/OpenUsageWidgets.appex"

echo "==> building WidgetKit extension ($CONFIGURATION, $WIDGET_ARCHS)"
BUILD_LOG="$DERIVED_DATA/xcodebuild.log"
mkdir -p "$DERIVED_DATA"
if ! xcodebuild \
  -project "$ROOT_DIR/OpenUsageWidgets.xcodeproj" \
  -scheme OpenUsageWidgets \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="${OPENUSAGE_TEAM_ID:-}" \
  ARCHS="$WIDGET_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$WIDGET_BUNDLE_ID" \
  OPENUSAGE_APP_GROUP="$OPENUSAGE_APP_GROUP" \
  OPENUSAGE_URL_SCHEME="$OPENUSAGE_URL_SCHEME" \
  MARKETING_VERSION="$WIDGET_VERSION" \
  CURRENT_PROJECT_VERSION="$WIDGET_BUILD" \
  build >"$BUILD_LOG" 2>&1; then
  echo "WidgetKit extension build failed; last 200 log lines:" >&2
  tail -n 200 "$BUILD_LOG" >&2
  exit 1
fi

[ -d "$PRODUCT" ] || { echo "missing widget extension: $PRODUCT" >&2; exit 1; }
rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
cp -R "$PRODUCT" "$DESTINATION"

WIDGET_BINARY="$DESTINATION/Contents/MacOS/OpenUsageWidgets"
[ -x "$WIDGET_BINARY" ] || { echo "missing widget binary: $WIDGET_BINARY" >&2; exit 1; }

actual_archs="$(lipo -archs "$WIDGET_BINARY")"
for arch in $WIDGET_ARCHS; do
  case " $actual_archs " in
    *" $arch "*) ;;
    *) echo "widget binary missing $arch slice (got: $actual_archs)" >&2; exit 1 ;;
  esac
done

INFO="$DESTINATION/Contents/Info.plist"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$INFO")" = "$WIDGET_BUNDLE_ID" ] \
  || { echo "widget bundle identifier mismatch" >&2; exit 1; }
[ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$INFO")" = "com.apple.widgetkit-extension" ] \
  || { echo "widget extension point is missing" >&2; exit 1; }
[ "$(plutil -extract OpenUsageAppGroupIdentifier raw -o - "$INFO")" = "$OPENUSAGE_APP_GROUP" ] \
  || { echo "widget App Group mismatch" >&2; exit 1; }
[ "$(plutil -extract OpenUsageURLScheme raw -o - "$INFO")" = "$OPENUSAGE_URL_SCHEME" ] \
  || { echo "widget URL scheme mismatch" >&2; exit 1; }

echo "    embedded: $DESTINATION"
