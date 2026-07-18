# Debugging and Capturing Logs

How to run a local build and watch what the app is doing — useful when a provider misbehaves or you're
chasing a startup or refresh problem.

## Run a local build

The project script owns the build/run loop. From the repo root:

```sh
./script/build_and_run.sh          # build and launch the dev app from dist/
./script/build_and_run.sh build    # build and stage only, don't launch
./script/build_and_run.sh verify   # launch and confirm the process is running
```

The script builds a signed app bundle under `dist/` and launches it in place — nothing is installed to
`/Applications`. The dev build uses its own bundle id (`com.robinebers.openusage.dev`), so it keeps its
own settings and keychain and never disturbs a released OpenUsage. It ships no update feed, so it never
checks for updates — test updates with a real signed, notarized release build.

## Stream logs

To watch the app's logs live while you reproduce an issue:

```sh
./script/build_and_run.sh logs
```

This launches the dev app and then streams its unified logs. Under the hood it filters the system log to
the app's process, equivalent to:

```sh
log stream --info --style compact --predicate 'process == "OpenUsage"'
```

To read logs *after the fact* instead of live, use `log show` with a time window:

```sh
log show --last 10m --info --predicate 'process == "OpenUsage"'
```

## Log file

In addition to the unified log above, the app writes a file log to
`~/Library/Logs/OpenUsage/OpenUsage.log` — this is what to send with a support report. It is capped at
~10 MB with one `.1` archive. Raise the detail in **Settings -> Advanced -> Log Level** (use **Debug**
for full detail), then grab the file with **Copy Log Path** or **Reveal in Finder** in that same
section. See [Logging](logging.md) for the levels, subsystem tags, and the never-log-secrets guarantee.

## Account log lines

The launch-time account pass (which account is signed in at the Claude/Codex default home) leaves a
short trail in the log file:

- `accounts: claude default identity resolved (claude@<hash>)` — the default login named its account.
  The hash is derived from the account id, so two launches by the same account always match.
- `accounts: codex default identity unresolved — …` — a login exists but its account can't be named
  with certainty this launch (an auth file without an account id, or a keychain credential whose
  secret we don't read at launch). The card works as before; it just can't participate in
  account-aware features yet.
- `stale account cache discarded for claude` — the account at the default home changed between
  launches, so the previous account's cached snapshot was dropped instead of painting under the new
  login.
- `account identity read skipped for claude, codex: login shell cold and no shell-environment
  snapshot exists yet` — a first launch raced a slow login shell, so the named families were left
  unread this launch; every later launch has a persisted snapshot to fall back on.

## Tips

- **A provider shows an error.** Reproduce with `logs` running, then check that provider's page in
  `docs/providers/` for what its error states mean and where it reads credentials from.
- **Nothing updates.** Refresh runs on a timer and respects the cache; see
  [Refreshing & caching](refreshing.md) for when a network call actually happens. Use the per-provider
  "Refresh" in the row's context menu to force one.
- **Permissions / keychain prompts on every rebuild.** The script signs with a stable Apple Development
  identity so the permission ACLs stick. If you see repeated prompts, make sure such an identity exists in
  your keychain (the script warns when it falls back to ad-hoc signing).
- **Inspect the local API.** With the app running, `curl 127.0.0.1:6736/v1/usage` shows the same usage
  snapshots the UI uses — handy to confirm whether a problem is in fetching/mapping or in the UI.
