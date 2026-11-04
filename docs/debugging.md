# Debugging

## Run a local build

```sh
./script/build_and_run.sh verify   # build, sign, launch, and confirm it runs
./script/build_and_run.sh logs     # launch and stream its log lines
```

- The dev bundle id is `com.robinebers.openusage.dev`. It keeps its own settings and Keychain items
  and runs beside an installed OpenUsage.
- It has no update feed, so the Updates controls are disabled. It leaves alone the OpenRouter and Z.ai
  keys 0.7.x saved.
- Only one dev build runs at a time. If one from another folder is running, `run` and `verify` fail
  and print its path.

## Sample Data (Development Only)

The local build script stages `dist/OpenUsage.app` and `dist/OpenUsage Demo.app`. In the normal dev
app, turn on **Settings → Advanced → Development → Sample Data**. The switch restarts in the isolated
demo app, with 15 sample accounts covering all 12 providers, an organization, and a hub. Turn it off
to restart the normal dev app with its existing accounts and settings.

- The demo uses `com.robinebers.openusage.dev.demo` and memory-only credential vaults. It never reads
  or changes the normal dev app's or installed app's accounts, settings, or Keychain items.
- Refresh, rename, reorder, hide, pin, and remove work on sample data. The demo's accounts, layout,
  and settings reset at each demo launch.
- The demo makes no provider or hub API calls and does not sign in, send telemetry, or run updates.
  Notifications, credential changes, and system integration controls are unavailable.
- The script passes `OPENUSAGE_DEVELOPMENT` only for local development identities. Production builds
  exclude the fixtures, switch, and activation code. Releases and the downloaded Test Build DMGs do
  not include Sample Data.

Rebuild with `./script/build_and_run.sh verify` if either app is missing. The switch starts the other
app before quitting the current one; a launch failure leaves the current app running.

## Read the logs

OpenUsage logs through unified logging under the subsystem `OpenUsage`, with categories such as
`refresh`, `http`, `auth`, `updates`, and `config`.

```sh
log stream --info --predicate 'subsystem == "OpenUsage"'
log stream --info --predicate 'subsystem == "OpenUsage" AND category == "refresh"'
log show --last 2h --predicate 'subsystem == "OpenUsage" AND category == "refresh"'
```

- macOS keeps info lines in memory only, so `log show` finds them for a few minutes at most. Each
  refresh pass's `batch start` and `batch end` lines go to disk, so the last command lists every pass.
- **Settings → Advanced → Log Level** sets how much is written: Info (the default), Debug (read with
  `--debug`), Warning, or Error.
- Logs never hold a URL's query, a header, or a response body. Tokens, keys, and home paths are masked.

## Tests

```sh
script/test_quiet.sh
script/test_quiet.sh --filter CursorTokenRefreshTests
script/test_quiet.sh -Xswiftc -DOPENUSAGE_DEVELOPMENT --filter 'DevelopmentDemoTests|DevelopmentDataModeTests'
```

The script runs the suite niced, keeps it from taking the keyboard or the screen, and fails the run if
a test process came to the front.
