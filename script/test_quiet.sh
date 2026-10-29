#!/usr/bin/env bash
# Runs the test suite without letting it take the keyboard. The tests host real windows in the
# xctest process on this Mac while its owner works in another app; this script watches the frontmost
# app throughout the run and fails when a test process ever came to the front. It also notes when the
# frontmost app at the end is not the one at the start, which is the owner switching apps as often as
# not, so that alone fails nothing. It is the only way to run tests on a Mac someone is using.
# Arguments go to `swift test` (for example --filter DashboardSectionTests).
#
# `--self-test` checks only the lsappinfo parse below, without lsappinfo or a test run.
#
# Usage: script/test_quiet.sh [--self-test | swift test arguments]
set -uo pipefail

display_name() {
  sed -nE 's/^"?LSDisplayName"? *= *"(.*)" *$/\1/p'
}

front_app() {
  lsappinfo info -only name "$(lsappinfo front)" | display_name
}

if [ "${1:-}" = --self-test ]; then
  for line in '"LSDisplayName"="Safari"' 'LSDisplayName = "Safari"'; do
    name="$(display_name <<< "$line")"
    [ "$name" = Safari ] || { echo "test_quiet: parsed '$line' as '$name', not 'Safari'" >&2; exit 1; }
  done
  echo "test_quiet: self-test passed"
  exit 0
fi

before="$(front_app)"
seen="$(mktemp -t test_quiet)"
is_test_process() {
  case "$1" in
    xctest|swift-*) return 0 ;;
    *) return 1 ;;
  esac
}
(
  trap 'kill $! 2>/dev/null; exit 0' TERM
  while true; do
    app="$(front_app)"
    is_test_process "$app" && echo "$app" >> "$seen"
    sleep 0.2 & wait $!
  done
) 2>/dev/null &
watcher=$!
disown "$watcher"
trap 'kill "$watcher" 2>/dev/null; rm -f "$seen"' EXIT

# The Swift Build layout links the test bundle against PackageFrameworks/ but builds Sparkle one level up.
frameworks="$(dirname "$0")/../.build/out/Products/Debug/PackageFrameworks"
mkdir -p "$frameworks"
[ -L "$frameworks/Sparkle.framework" ] || ln -s ../Sparkle.framework "$frameworks/Sparkle.framework"

nice -n 19 swift test -j 2 "$@"
status=$?

after="$(front_app)"
if [ -s "$seen" ] || is_test_process "$after"; then
  echo "test_quiet: the suite took the keyboard: $(sort -u "$seen" | tr '\n' ' ')came to the front during the run" >&2
  exit 2
fi
if [ "$before" != "$after" ]; then
  echo "test_quiet: the frontmost app changed from '$before' to '$after' during the run, with no test process in front"
else
  echo "test_quiet: the frontmost app stayed '$before'"
fi
exit $status
