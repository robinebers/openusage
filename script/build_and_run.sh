#!/usr/bin/env bash
set -euo pipefail

# Builds OpenUsage, stages a signed .app bundle under dist/, and launches it in place — no install
# to /Applications. The dev build:
#   - is signed with a stable Apple Development identity, so keychain/permission grants stick across
#     rebuilds (macOS keys those to the signing identity + bundle id, not the install location);
#   - uses its own bundle id (com.robinebers.openusage.dev), so it never touches the real installed
#     app's settings or keychain. To run against the real app's data instead, set BUNDLE_ID to
#     com.robinebers.openusage below;
#   - ships no Sparkle feed, so it never checks for or installs updates (test updates with a real
#     signed + notarized release build — that's the only honest way).
#
# Usage: script/build_and_run.sh [run|build|logs|verify]
# Env:   CODESIGN_IDENTITY  override signing identity (exact name or hash)
#        OPENUSAGE_TEAM_ID  Apple Developer team id (normally inferred from the identity)
#        WIDGETS_REQUIRED   set to 1 to fail instead of producing a host-only ad-hoc build
#        CONFIG             "release" (default) or "debug"

MODE="${1:-run}"
CONFIG="${CONFIG:-release}"

TARGET_NAME="OpenUsage"                 # SwiftPM target / binary name
APP_DISPLAY="OpenUsage"                 # user-facing app name
BUNDLE_ID="${BUNDLE_ID:-com.robinebers.openusage.dev}"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="0.7.0"
APP_BUILD="0.7.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="${TARGET_NAME}_${TARGET_NAME}.bundle"
ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.dev.entitlements.plist"
WIDGET_BUNDLE_ID="$BUNDLE_ID.widgets"
if [ "$BUNDLE_ID" = "com.robinebers.openusage" ]; then
  OPENUSAGE_URL_SCHEME="${OPENUSAGE_URL_SCHEME:-openusage}"
else
  OPENUSAGE_URL_SCHEME="${OPENUSAGE_URL_SCHEME:-openusage-dev}"
fi

# WidgetKit/App Groups need stable team-signed identities. Keep the existing ad-hoc host-only fallback
# for contributors without an Apple Development certificate; widget work can demand the full path with
# WIDGETS_REQUIRED=1 so a missing identity never looks like a successful widget build.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi
OPENUSAGE_TEAM_ID="${OPENUSAGE_TEAM_ID:-}"
if [ -z "$OPENUSAGE_TEAM_ID" ] && [ -n "$CODESIGN_IDENTITY" ]; then
  # The value in parentheses in an Apple Development identity is not guaranteed to be the
  # certificate's Team ID. The authoritative team identifier is the subject OU.
  CERTIFICATE_NAME="$CODESIGN_IDENTITY"
  if printf '%s' "$CODESIGN_IDENTITY" | /usr/bin/grep -Eq '^[[:xdigit:]]{40}$'; then
    CERTIFICATE_NAME=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
      | /usr/bin/awk -v wanted="$CODESIGN_IDENTITY" '
          toupper($2) == toupper(wanted) { split($0, fields, "\""); print fields[2]; exit }
        ')
  fi
  if [ -n "$CERTIFICATE_NAME" ]; then
    OPENUSAGE_TEAM_ID=$(/usr/bin/security find-certificate -c "$CERTIFICATE_NAME" -p 2>/dev/null \
      | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/sed -n 's/^OU=\([A-Z0-9][A-Z0-9]*\)$/\1/p' \
      | /usr/bin/head -n 1)
  fi
fi

WIDGETS_ENABLED=0
OPENUSAGE_APP_GROUP=""
if [ -n "$CODESIGN_IDENTITY" ] && [ -n "$OPENUSAGE_TEAM_ID" ]; then
  WIDGETS_ENABLED=1
  OPENUSAGE_APP_GROUP="$OPENUSAGE_TEAM_ID.$BUNDLE_ID.shared"
elif [ "${WIDGETS_REQUIRED:-0}" = "1" ]; then
  echo "Widget build requires an Apple Development identity and OPENUSAGE_TEAM_ID." >&2
  exit 1
else
  echo "WARNING: no team-signed identity; building the host app without WidgetKit support." >&2
fi

pkill -x "$TARGET_NAME" >/dev/null 2>&1 || true

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real
# SDK it compiled against. macOS gates the modern Liquid Glass control appearance (pop-up buttons,
# pickers, etc.) on the linked SDK — a "15.0" stamp makes AppKit fall back to legacy Aqua controls.
# Restamp the sdk to 26.0 (Tahoe, where Liquid Glass landed) while keeping minos at MIN_SYSTEM_VERSION
# so the app still runs on macOS 15 but gets the modern controls. Re-signed below.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Stage every SwiftPM resource bundle produced by the build (the app's own
# OpenUsage_OpenUsage.bundle, which carries the provider SVGs + model manifest)
# into Contents/Resources, the standard app layout. Bundle.openUsageResources
# (see Support/ResourceBundle.swift) loads it from there.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Compile the Icon Composer source (assets/AppIcon.icon) into Assets.car so
# Tahoe renders the real Liquid Glass icon. CFBundleIconName below must match
# the .icon file stem ("AppIcon"). The app floor is macOS 15, so a classic .icns
# fallback is relevant there (the release build supplies one); this dev build only
# stages the Assets.car and runs on the maintainer's current OS.
echo "==> compiling app icon (actool)"
PREBUILT_ICON_DIR="$ROOT_DIR/assets/AppIcon.prebuilt"
if xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text --errors --warnings; then
  : # compiled the icon fresh
elif [ -f "$PREBUILT_ICON_DIR/Assets.car" ]; then
  # actool is broken on some toolchains; commit 08863d7 ships a prebuilt icon so release CI bypasses
  # it. Reuse the same prebuilt here, so a failed actool doesn't abort the dev build under set -e and
  # the app still gets its real icon.
  echo "==> actool failed; using prebuilt icon (assets/AppIcon.prebuilt)"
  cp "$PREBUILT_ICON_DIR/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$PREBUILT_ICON_DIR/AppIcon.icns" ] && cp "$PREBUILT_ICON_DIR/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "WARNING: actool failed and no prebuilt icon found; continuing without an icon" >&2
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION-dev</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>OpenUsageAppGroupIdentifier</key>
  <string>$OPENUSAGE_APP_GROUP</string>
  <key>OpenUsageURLScheme</key>
  <string>$OPENUSAGE_URL_SCHEME</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.provider</string>
      <key>CFBundleURLSchemes</key>
      <array><string>$OPENUSAGE_URL_SCHEME</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ "$WIDGETS_ENABLED" = "1" ]; then
  WIDGET_CONFIGURATION=Release
  [ "$CONFIG" = "debug" ] && WIDGET_CONFIGURATION=Debug
  APP_BUNDLE="$APP_BUNDLE" \
  WIDGET_BUNDLE_ID="$WIDGET_BUNDLE_ID" \
  OPENUSAGE_APP_GROUP="$OPENUSAGE_APP_GROUP" \
  OPENUSAGE_URL_SCHEME="$OPENUSAGE_URL_SCHEME" \
  OPENUSAGE_TEAM_ID="$OPENUSAGE_TEAM_ID" \
  WIDGET_VERSION="$APP_VERSION-dev" \
  WIDGET_BUILD="$APP_BUILD" \
  WIDGET_ARCHS="$(uname -m)" \
  WIDGET_CONFIGURATION="$WIDGET_CONFIGURATION" \
    "$ROOT_DIR/script/build_widget_extension.sh"
fi

# Embed + sign Sparkle.framework before sealing the app. The executable links Sparkle, so without the
# embedded framework the build would fail to launch — even though the updater stays dormant here (no
# SUFeedURL in the Info.plist above; see UpdaterController).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime"

if [ -n "$CODESIGN_IDENTITY" ]; then
  HOST_ENTITLEMENTS="$DIST_DIR/OpenUsage.host.entitlements.plist"
  if [ "$WIDGETS_ENABLED" = "1" ]; then
    cat >"$HOST_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.get-task-allow</key><true/>
  <key>com.apple.security.application-groups</key>
  <array><string>$OPENUSAGE_APP_GROUP</string></array>
</dict></plist>
PLIST
    WIDGET_ENTITLEMENTS="$DIST_DIR/OpenUsage.widget.entitlements.plist"
    cat >"$WIDGET_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key>
  <array><string>$OPENUSAGE_APP_GROUP</string></array>
</dict></plist>
PLIST
    /usr/bin/codesign --force --options runtime \
      --sign "$CODESIGN_IDENTITY" \
      --entitlements "$WIDGET_ENTITLEMENTS" \
      "$APP_BUNDLE/Contents/PlugIns/OpenUsageWidgets.appex" >/dev/null
  else
    HOST_ENTITLEMENTS="$ENTITLEMENTS"
  fi
  # Not --deep: the Sparkle framework is already signed above and must keep that signature.
  /usr/bin/codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$HOST_ENTITLEMENTS" \
    "$APP_BUNDLE" >/dev/null
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "WARNING: no Apple Development identity found; ad-hoc signed." >&2
fi

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    launch_app
    echo "==> launched $APP_DISPLAY (dist/$APP_DISPLAY.app)"
    ;;
  build)
    : # build + stage + sign only
    ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$TARGET_NAME\""
    ;;
  verify)
    launch_app
    sleep 1
    pgrep -x "$TARGET_NAME" >/dev/null && echo "==> running"
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
