#!/usr/bin/env bash
set -euo pipefail

# Builds a distributable, Developer ID-signed, notarized OpenUsage.app and wraps it in a DMG. The app
# is a universal binary (arm64 + x86_64) so it runs on both Apple Silicon and Intel Macs; the DMG is the
# only output. The appcast is produced separately by Sparkle's generate_appcast (in release.yml), which
# signs the DMG with the EdDSA key and writes/updates appcast.xml. Runs in CI (release.yml) and locally
# on a Mac with the same env. This script does NOT push anything to GitHub.
#
# Required env:
#   CODESIGN_IDENTITY     Developer ID Application identity (name or hash)
#   SPARKLE_PUBLIC_KEY    base64 EdDSA public key -> baked into Info.plist (SUPublicEDKey). generate_appcast
#                         only signs the DMG if this matches the private key it signs with.
#   OPENUSAGE_VERSION     human version, e.g. 0.7.0 (CFBundleShortVersionString)
# Optional env:
#   OPENUSAGE_BUILD       CFBundleVersion (monotonic). Default: git commit count.
#   FEED_URL              appcast URL baked into the app. Default: GitHub Pages project URL.
#   NOTARY_APPLE_ID / NOTARY_APP_PASSWORD / NOTARY_TEAM_ID   Apple ID, app-specific password, and team
#                         ID for notarytool. When all three are set, the app and DMG are notarized + stapled.
#   ALLOW_UNNOTARIZED=1   Skip notarization for a LOCAL dry run. Without it, missing notary creds is a
#                         hard error so CI never publishes an un-notarized build.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${SPARKLE_PUBLIC_KEY:?set SPARKLE_PUBLIC_KEY to your base64 EdDSA public key}"
: "${OPENUSAGE_VERSION:?set OPENUSAGE_VERSION, e.g. 0.7.0}"

APP_NAME="OpenUsage"
BUNDLE_ID="com.robinebers.openusage"
MIN_SYSTEM_VERSION="15.0"
VERSION="$OPENUSAGE_VERSION"
# CFBundleShortVersionString carries the full version, including any pre-release suffix (e.g.
# "0.7.0-beta.1"). This is the human-readable string Sparkle shows in its update prompt and the app
# shows in its footer/About, so they always match. Sparkle compares builds by CFBundleVersion (the
# monotonic commit count below), not this string, and Developer ID notarization does not require it to
# be numeric. (Sparkle's own docs use a beta short version, e.g. "2.0b1".)
BUILD="${OPENUSAGE_BUILD:-$(git rev-list --count HEAD)}"
FEED_URL="${FEED_URL:-https://robinebers.github.io/openusage/appcast.xml}"
DMG_NAME="$APP_NAME-$VERSION.dmg"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# Decide notarization up front. CI always supplies the notarization login; a local dry run can
# opt out with ALLOW_UNNOTARIZED=1 (the build will then be Gatekeeper-blocked on other Macs). Missing
# creds without that opt-out is a hard error so CI never publishes an un-notarized DMG.
NOTARIZE=0
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_APP_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
  NOTARIZE=1
elif [ "${ALLOW_UNNOTARIZED:-}" = "1" ]; then
  echo "WARNING: ALLOW_UNNOTARIZED=1 — build will NOT be notarized (other Macs will block it)." >&2
else
  echo "Notarization creds missing (NOTARY_APPLE_ID / NOTARY_APP_PASSWORD / NOTARY_TEAM_ID)." >&2
  echo "Set them, or set ALLOW_UNNOTARIZED=1 for a local dry run." >&2
  exit 1
fi

notarize() {  # $1: artifact to submit (.zip or .dmg)
  xcrun notarytool submit "$1" \
    --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_APP_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
}

echo "==> building $APP_NAME $VERSION ($BUILD) — universal (arm64 + x86_64)"
# Build both arch slices and let SwiftPM lipo-merge them into one universal binary. With multiple
# --arch, --show-bin-path resolves to the merged products dir (.build/apple/Products/Release), which
# also holds the *.bundle resources, so the staging loop below is unchanged.
swift build -c release --arch arm64 --arch x86_64
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
[ -x "$BUILD_BINARY" ] || { echo "missing built binary: $BUILD_BINARY" >&2; exit 1; }

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Fail loudly if the build ever silently regresses to a single arch (e.g. a dropped --arch flag): a
# fat binary is the whole point, and generate_appcast derives Sparkle's hardwareRequirements from it.
lipo -archs "$APP_BINARY" | grep -q "x86_64" && lipo -archs "$APP_BINARY" | grep -q "arm64" \
  || { echo "Expected a universal (arm64 + x86_64) binary, got: $(lipo -archs "$APP_BINARY")" >&2; exit 1; }

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real
# SDK it compiled against. macOS gates the modern Liquid Glass control appearance (pop-up buttons,
# pickers, etc.) on the linked SDK — a "15.0" stamp makes AppKit fall back to legacy Aqua controls.
# Restamp the sdk to 26.0 (Tahoe) while keeping minos at MIN_SYSTEM_VERSION so the app still runs on
# macOS 15 but gets the modern controls. Stamps every slice of the universal binary; re-signed below.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Fail loudly if any slice still reports the old SDK (a silent vtool no-op would ship legacy controls).
if vtool -show-build "$APP_BINARY" | grep -q "sdk 15.0"; then
  echo "SDK restamp failed: $APP_BINARY still reports sdk 15.0" >&2
  exit 1
fi
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Install the app icon. Prefer the prebuilt compiled catalog: actool on GitHub's runners (Xcode 26.4.1
# and 26.5) crashes on the Icon Composer `.icon` refractivity feature (Apple regression FB20183399), so
# CI can't compile it. The committed Assets.car is produced by a working actool via script/compile_icon.sh;
# regenerate it there whenever assets/AppIcon.icon changes. Fall back to actool where it works (e.g. local).
if [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" ]; then
  echo "==> installing prebuilt app icon"
  cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" ] \
    && cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "==> compiling app icon"
  xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
    --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings
fi

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST

# Embed + sign Sparkle (Developer ID, hardened runtime, secure timestamp).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime --timestamp"

echo "==> signing app (Developer ID, hardened runtime)"
# Not --deep: the Sparkle framework is signed above and must keep that signature. No get-task-allow
# entitlement (that debug flag would fail notarization); a non-sandboxed app needs no entitlements.
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# Notarize + staple the app itself (not just the DMG) so it launches cleanly even offline after a
# Sparkle update extracts it from the disk image.
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing app (this can take a few minutes)"
  APP_ZIP="$DIST_DIR/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$APP_ZIP"
fi

echo "==> building $DMG_PATH"
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"

# Notarize + staple the DMG too, so the first manual download isn't Gatekeeper-blocked.
if [ "$NOTARIZE" = "1" ]; then
  echo "==> notarizing dmg"
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "==> notarized + stapled"
fi

echo "==> done"
echo "    DMG: $DMG_PATH"
echo "    The appcast is generated from this DMG by generate_appcast (see release.yml)."
