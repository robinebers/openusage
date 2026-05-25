# Resource Budget Diagnostics

Use this guide when OpenUsage looks heavy in the background, or when a PR changes probe scheduling, provider execution, child processes, the local HTTP API, or hidden-panel UI timers.

The goal is not to enforce a single exact CPU or memory number. OpenUsage runs as a Tauri menu bar app, so the main process, WebKit processes, OS networking, and provider helper commands can all show up separately. The goal is to capture comparable before/after data and to identify which part of the app is responsible for background work.

## Quick Baseline

Run this with OpenUsage started, the panel hidden, and no manual refresh in progress:

```bash
PID=$(pgrep -fn "OpenUsage|openusage")
top -l 5 -s 1 -pid "$PID" -stats pid,cpu,mem,threads,ports,command
ps -M "$PID" | wc -l
lsof -nP -a -p "$PID" -iTCP
```

A healthy short idle sample should generally show:

- low main-process CPU, commonly near `0.0%` with only brief spikes;
- stable memory across repeated samples rather than steady growth;
- a small, stable thread count while no refresh is running;
- no unexpected public network listener; the local HTTP API, when enabled, should be loopback-only.

Treat these as investigation hints, not hard pass/fail limits. Provider mix, WebKit state, log level, macOS version, and whether a refresh is running can all move the numbers.

## Long Idle Watch

For suspected background drift, capture a longer hidden-panel sample:

```bash
PID=$(pgrep -fn "OpenUsage|openusage")
while true; do
  date
  top -l 1 -s 0 -pid "$PID" -stats pid,cpu,mem,threads,ports,command | tail -n +8
  sleep 60
done
```

Useful signals:

- CPU should return to near idle between scheduled refreshes.
- Memory should not climb continuously for hours without returning to a stable range.
- Thread count should not grow after each local API request or provider refresh.

## Child Process Watch

Use this while triggering manual refreshes or waiting for an auto refresh:

```bash
PID=$(pgrep -fn "OpenUsage|openusage")
while true; do
  ps -Ao pid,ppid,stat,comm,args | awk -v p="$PID" '$2==p || /ccusage|bunx|npx|npm|pnpm|sqlite3|security/'
  sleep 0.2
done
```

Expected behavior:

- helper commands may appear during a refresh;
- helper commands should exit after the provider finishes or times out;
- no zombie children should remain owned by the OpenUsage process;
- repeated refreshes should not leave an increasing number of `ccusage`, `bunx`, `npx`, `sqlite3`, `security`, `ps`, or `lsof` processes.

## Local HTTP API Stress

The local API should remain loopback-only and should not create unbounded worker threads under stress.

```bash
for i in {1..500}; do
  curl -s http://127.0.0.1:6736/v1/usage >/dev/null &
done
wait
```

Watch the main process thread count during and after the stress run:

```bash
PID=$(pgrep -fn "OpenUsage|openusage")
top -l 10 -s 1 -pid "$PID" -stats pid,cpu,mem,threads,ports,command
```

Expected behavior:

- transient CPU and thread activity during the stress run is acceptable;
- thread count should settle back after requests complete;
- the app should remain responsive;
- repeated stress runs should not leave a higher idle thread count each time.

## Provider Probe Timing

When a provider feels slow or expensive, collect a focused log window:

1. Set `Debug Level` to `Debug`.
2. Start one manual refresh.
3. Wait until it finishes or clearly times out.
4. Save `~/Library/Logs/com.sunstory.openusage/openusage.log`.

In the issue or PR, include:

```text
OpenUsage version:
macOS version:
Provider(s) enabled:
Provider(s) refreshed:
Auto-update interval:
Panel state during test: hidden / visible
Debug log attached: yes / no
Observed CPU/memory/thread behavior:
Child processes left after refresh:
```

See [capture logs](capture-logs.md) for the user-facing log collection steps.

## PR Review Checklist

For PRs that touch background refreshes or helper commands, check:

- Does the same provider avoid overlapping probes?
- Is batch fan-out bounded?
- Does slow plugin work have a clear timeout or cancellation path?
- Do helper commands have a timeout and bounded output?
- Do hidden-panel UI timers pause or avoid one-second React work?
- Are local API connections bounded?
- Are cache writes coalesced when multiple provider results arrive close together?
- Can logs or diagnostics identify the slow provider or helper command?

If the PR intentionally changes background behavior, include before/after output from the relevant sections above in the PR description.
