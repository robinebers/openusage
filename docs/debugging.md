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

## Multi-account discovery

When someone reports "my second account didn't show up" (or "shows the wrong data"), the default log
already contains the whole story — no debug build needed. Look for these lines from launch, in order:

- `provider-instance discovery: …` — the outcome: how many extra logins, of which kinds, and how long
  the scan took.
- `provider-instance discovery skipped: login-shell environment did not warm before the launch deadline`
  — the shell-only default homes were not ready in time, so extra-account cards are safely suppressed
  for this launch and discovery retries next launch instead of mislabeling the default home as an extra.
- `discovery: default identities: claude=<hash> codex=[…]` — which account each **default** card
  resolved to. The 8-char hash matches the instance-id suffix (`claude@<hash>`), so cards and
  identities correlate directly.
- `discovery: <provider> candidate <path>: …` — one line per near-miss with the exact reason:
  `accepted`, `folded` (same account as an existing card — the most common "where is it?" answer),
  `no credential`, or `identity file present but unreadable`. Random dot-dirs never appear; only
  candidates that carried identity or credential shape.
- An unverified keyring-only Codex home is hidden for that launch and warmed through one exact,
  account-scoped read after launch. It appears on the next launch; that warm may show macOS's normal
  one-time Keychain permission dialog, and a replaced item invalidates the cached account binding.
- `discovery: cswap vault …` / `cswap slot N: …` — the claude-swap picture: slot count, which slot is
  active (that one *is* the default card), which parked slots became instances and why others didn't.
- `discovery: cowork partition: …` — how Cowork sandboxes split across accounts.
- `instance registry: <id> ordinal=N kind=… anchor=…` — every persisted account card, every launch,
  including ones suppressed because they currently match the default login.
- The per-refresh `refresh start (N sources: …)` line then explains credential selection per card
  (source kind, `refresh=yes/no`, `expired=yes/no`).

All of it is token-free and email-free by construction — identity hashes, paths, and kinds only — so
the log stays safe to attach to a public issue.

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
