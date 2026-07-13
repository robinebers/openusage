#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="${1:?entitlements template path required}"
PROFILE="${2:?provisioning profile path required}"
OUTPUT="${3:?resolved entitlements output path required}"
CONTAINER_ID="${4:?iCloud container identifier required}"

PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
/usr/bin/security cms -D -i "$PROFILE" > "$PROFILE_PLIST"

TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
[ -n "$TEAM_ID" ] || { echo "provisioning profile has no team identifier" >&2; exit 1; }

APP_ID="$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
[ -n "$APP_ID" ] || { echo "provisioning profile has no application identifier" >&2; exit 1; }

/usr/libexec/PlistBuddy \
  -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$PROFILE_PLIST" \
  | /usr/bin/grep -Fq "$CONTAINER_ID" \
  || { echo "provisioning profile does not allow $CONTAINER_ID" >&2; exit 1; }

UBIQUITY_ID="$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.developer.ubiquity-container-identifiers:0' "$PROFILE_PLIST")"
case "$UBIQUITY_ID" in
  "$CONTAINER_ID"|"$TEAM_ID.$CONTAINER_ID") ;;
  *) echo "provisioning profile does not allow a ubiquity container for $CONTAINER_ID" >&2; exit 1 ;;
esac

/bin/cp "$TEMPLATE" "$OUTPUT"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.developer.ubiquity-container-identifiers:0 $UBIQUITY_ID" "$OUTPUT"

# Xcode normally injects these identity entitlements while signing. This repository signs the
# SwiftPM-built bundle directly with codesign, so derive them from the provisioning profile instead.
# Without them taskgated rejects an otherwise valid signature before the app can launch.
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string $APP_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
  -c "Add :keychain-access-groups array" \
  -c "Add :keychain-access-groups:0 string $APP_ID" \
  "$OUTPUT"

if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices:0' "$PROFILE_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.developer.icloud-container-environment string Development' \
    -c 'Add :com.apple.developer.icloud-container-development-container-identifiers array' \
    -c "Add :com.apple.developer.icloud-container-development-container-identifiers:0 string $CONTAINER_ID" \
    "$OUTPUT"
else
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.developer.icloud-container-environment string Production' \
    "$OUTPUT"
fi
/usr/bin/plutil -lint "$OUTPUT" >/dev/null
