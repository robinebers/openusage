#!/usr/bin/env bash
set -euo pipefail

# Embeds Sparkle.framework into an already-staged .app bundle and signs it.
#
# SwiftPM resolves Sparkle as a binary xcframework under .build/artifacts and links the executable
# against it via @rpath, but it does NOT copy the framework into the app bundle the way Xcode would.
# A hand-built bundle therefore has to: copy the framework into Contents/Frameworks, add the runtime
# search path so the binary finds it there, and code-sign the framework (the caller signs the outer
# app bundle afterwards, WITHOUT --deep, so this signature is preserved).
#
# Usage: embed_sparkle.sh <app_bundle> <app_binary> [signing_identity] [extra_codesign_flags]
#   signing_identity      exact identity name/hash, or empty for ad-hoc ("-")
#   extra_codesign_flags  e.g. "--options runtime --timestamp" (word-split on purpose)

APP_BUNDLE="$1"
APP_BINARY="$2"
SIGN_ID="${3:--}"
EXTRA_FLAGS="${4:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prefer the universal macOS slice; fall back to whatever Sparkle.framework exists in the artifacts.
SPARKLE_FW="$(/usr/bin/find "$ROOT_DIR/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -n1)"
if [ -z "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(/usr/bin/find "$ROOT_DIR/.build/artifacts" -type d -name "Sparkle.framework" 2>/dev/null | head -n1)"
fi
if [ -z "$SPARKLE_FW" ]; then
  echo "Sparkle.framework not found under .build/artifacts — run 'swift build' first." >&2
  exit 1
fi

FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
rm -rf "$FRAMEWORKS/Sparkle.framework"
# ditto preserves the framework's version symlinks and signature layout (cp -R can flatten them).
ditto "$SPARKLE_FW" "$FRAMEWORKS/Sparkle.framework"

# OpenUsage is not sandboxed, so Sparkle's XPC services are unnecessary. Removing them avoids the
# nested-XPC signing/entitlements dance and the "error launching the installer" failure some
# non-sandboxed apps hit when launchd refuses the XPC services. Glob the version letter (Sparkle has
# used letters other than "B") so this never silently no-ops and leaves XPC services for --deep to hit.
rm -rf "$FRAMEWORKS"/Sparkle.framework/Versions/*/XPCServices
rm -f  "$FRAMEWORKS/Sparkle.framework/XPCServices"

# SwiftPM only bakes @loader_path into the executable; the bundled binary needs this rpath to resolve
# @rpath/Sparkle.framework from Contents/Frameworks. Add it only if missing (re-runs would otherwise
# error on a duplicate) — but let any genuine install_name_tool failure surface instead of hiding it.
if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
fi

# ditto preserves whatever extended attributes the downloaded artifact carries
# (notably com.apple.FinderInfo), which codesign rejects as detritus — strip
# them before signing. Plain `xattr -cr` silently skips some of these, so
# delete by name and ignore per-file errors.
find "$FRAMEWORKS/Sparkle.framework" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true

# Sign the framework (and its remaining nested helpers: Autoupdate + Updater.app) with our identity so
# the whole bundle is single-team-signed for notarization. --deep is safe here precisely because the
# XPC services (the components that must never be deep-signed) have been removed above.
# shellcheck disable=SC2086
codesign --force --deep $EXTRA_FLAGS --sign "$SIGN_ID" "$FRAMEWORKS/Sparkle.framework"

echo "==> embedded + signed Sparkle.framework (identity: $SIGN_ID)"
