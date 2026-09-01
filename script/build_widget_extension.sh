#!/usr/bin/env bash
set -euo pipefail

CONFIG_INPUT="${1:?configuration required (debug or release)}"
WIDGET_BUNDLE_ID="${2:?widget bundle identifier required}"
VERSION="${3:?bundle version required}"
BUILD="${4:?bundle build required}"
MIN_SYSTEM_VERSION="${5:?minimum system version required}"
ARCHS="${6:-$(uname -m)}"
LOWER_CONFIG=$(printf '%s' "$CONFIG_INPUT" | tr '[:upper:]' '[:lower:]')

case "$LOWER_CONFIG" in
  debug) CONFIG="Debug" ;;
  release) CONFIG="Release" ;;
  *) echo "unsupported widget configuration: $CONFIG_INPUT" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/WidgetExtension/OpenUsageWidgetExtension.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/xcode-widget-extension-$LOWER_CONFIG"
APPEX="$DERIVED_DATA/Build/Products/$CONFIG/OpenUsageWidgetExtension.appex"
BINARY="$APPEX/Contents/MacOS/OpenUsageWidgetExtension"

echo "==> building real WidgetKit app extension ($CONFIG, $ARCHS)" >&2
xcodebuild \
  -project "$PROJECT" \
  -scheme OpenUsageWidgetExtension \
  -configuration "$CONFIG" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  OPENUSAGE_WIDGET_BUNDLE_ID="$WIDGET_BUNDLE_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  build >&2

[ -x "$BINARY" ] || { echo "missing Xcode-built widget extension: $BINARY" >&2; exit 1; }
printf '%s\n' "$APPEX"
