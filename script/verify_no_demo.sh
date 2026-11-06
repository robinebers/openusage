#!/usr/bin/env bash
# Asserts that production app/CLI executables do not contain the development demo.
# Build in a fresh scratch directory without OPENUSAGE_DEVELOPMENT, then pass both executables here.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <production-executable> [production-executable ...]" >&2
  exit 1
fi

inspection_dir="$(mktemp -d -t openusage-no-demo)"
trap 'rm -rf "$inspection_dir"' EXIT

assert_no_matches() {
  local binary="$1" description="$2" status
  shift 2
  if /usr/bin/grep "$@"; then
    echo "error: development demo $description found in $binary" >&2
    exit 1
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      echo "error: could not inspect $description in $binary (grep exited $status)" >&2
      exit 1
    fi
  fi
}

for binary in "$@"; do
  [ -x "$binary" ] || { echo "missing executable: $binary" >&2; exit 1; }
  /usr/bin/nm "$binary" > "$inspection_dir/symbols"
  /usr/bin/strings -a "$binary" > "$inspection_dir/strings"
  assert_no_matches "$binary" symbols -Eq \
    '\$s9OpenUsage[0-9]+(Demo|DevelopmentData)' \
    "$inspection_dir/symbols"
  assert_no_matches "$binary" 'data or controls' -Fqx \
    -e 'com.robinebers.openusage.dev.demo' \
    -e 'Sample Data' \
    -e 'Demo Data' \
    -e 'OpenUsage Demo' \
    "$inspection_dir/strings"
  echo "==> no development demo in $(basename "$binary")"
done
