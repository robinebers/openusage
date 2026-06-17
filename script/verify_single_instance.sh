#!/usr/bin/env bash
set -uo pipefail

# Manual integration repro for the single-instance guard (issue #635, SingleInstanceGuard.swift).
#
# The guard rejects a second copy of OpenUsage at launch. The hard case it targets is a reboot, where
# macOS session restoration ("Reopen windows when logging back in") and the SMAppService login item
# fire two launches at once. But the guard never asks *why* a second launch happened — it only sees
# "is another instance of my bundle id alive?". A reboot is just one way to produce concurrent
# launches; `open -n` (force a new instance, bypassing LaunchServices' dedup) is another. So this
# script exercises the exact guard code path WITHOUT a reboot.
#
# CI can't run this (no window server, no signing identity), so it is a local tool — not wired into
# `swift test`. The deterministic decision (lowest-PID-wins tie-break) is unit-tested in
# SingleInstanceGuardTests; this confirms the live wiring on a real signed .app.
#
# It drives the DEV build only (bundle id com.robinebers.openusage.dev), and counts/kills by bundle
# PATH, so it never touches an installed com.robinebers.openusage. Requires the guard to be present in
# the build (merge/checkout PR #637 first), otherwise every scenario "fails" because nothing dedupes.
#
# Usage: script/verify_single_instance.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/OpenUsage.app"
# Path-scoped so pgrep/pkill match only this dev build, never an installed copy of the same name.
PATTERN="$APP/Contents/MacOS/OpenUsage"
FAILED=0

count() { pgrep -f "$PATTERN" 2>/dev/null | wc -l | tr -d ' '; }
kill_dev() { pkill -f "$PATTERN" 2>/dev/null || true; }
guard_logged_handoff() {
  log show --last 30s --info --predicate 'process == "OpenUsage"' 2>/dev/null \
    | grep -q "duplicate launch detected"
}

trap 'kill_dev; sleep 1' EXIT

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then echo "  ✓ $1 (got $3)"; else echo "  ✗ $1 (expected $2, got $3)"; FAILED=1; fi
}
assert_ge() { # label min actual
  if [ "$3" -ge "$2" ]; then echo "  ✓ $1 (got $3)"; else echo "  ✗ $1 (expected ≥ $2, got $3)"; FAILED=1; fi
}

if [ ! -d "$APP" ]; then
  echo "==> staging dev app (dist/OpenUsage.app)…"
  "$ROOT_DIR/script/build_and_run.sh" build
fi

echo "== A. a second launch is rejected (duplicate / lingering case) =="
kill_dev; sleep 1
open -n "$APP"; sleep 2          # instance 1 takes the slot
open -n "$APP"; sleep 2          # instance 2 should detect it, hand off, and terminate
assert_eq "exactly one instance survives" 1 "$(count)"
if guard_logged_handoff; then echo "  ✓ guard logged the handoff"; else echo "  ⚠ no [lifecycle] handoff line found (verify manually)"; fi
kill_dev; sleep 1

echo "== B. simultaneous race ×15 (the reboot scenario) — must NEVER drop to zero =="
# The regression this guards against: the old 'yield to any other instance' rule made both
# simultaneous launches terminate (zero instances). With lowest-PID-wins the count is always ≥ 1.
# A transient 2 is the NSRunningApplication ceiling (neither launch registered before the other
# evaluated), not a logic bug — reported, not failed.
ones=0; twos=0
for i in $(seq 1 15); do
  open -n "$APP" & open -n "$APP" &
  wait; sleep 2
  n="$(count)"
  assert_ge "run $i never zero" 1 "$n"
  [ "$n" = 1 ] && ones=$((ones + 1))
  [ "$n" = 2 ] && twos=$((twos + 1))
  kill_dev; sleep 1
done
echo "  → exactly-one: $ones/15   transient-two: $twos/15"

echo "== C. a hung instance still holding 127.0.0.1:6736 (the crash report) =="
kill_dev; sleep 1
open -n "$APP"; sleep 2
first="$(pgrep -f "$PATTERN" | head -1)"
kill -STOP "$first" 2>/dev/null || true     # freeze instance 1; it keeps the port
if lsof -nP -iTCP:6736 -sTCP:LISTEN >/dev/null 2>&1; then echo "  • port 6736 still held by the frozen instance"; else echo "  • (port not detected — continuing)"; fi
open -n "$APP"; sleep 2
assert_eq "new launch defers to the frozen instance" 1 "$(count)"
kill -CONT "$first" 2>/dev/null || true
kill_dev; sleep 1

echo
if [ "$FAILED" = 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$FAILED"
