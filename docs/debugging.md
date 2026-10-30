# Debugging

## Run a local build

```sh
./script/build_and_run.sh verify
```

The script stops the dev build if it is running, builds the package, stages `dist/OpenUsage.app`,
embeds Sparkle, signs the bundle with your Apple Development identity (ad hoc when none is installed),
launches it, and confirms the process is up. The dev bundle id is `com.robinebers.openusage.dev`, so
it keeps its own settings and Keychain items and runs beside an installed OpenUsage. It has no update
feed, so the Updates section does not show.

Every dev build shares one single-instance lock, so a copy launched while a dev build from another
folder runs hands off to that copy and quits. `run` and `verify` then fail and print the running
copy's path.

`./script/build_and_run.sh logs` launches the app and streams its log lines.

Widgets need an Apple Development identity and team id. The script infers the team from the signing
certificate, or accepts `OPENUSAGE_TEAM_ID`. Without both, it warns and builds the host without widgets;
set `WIDGETS_REQUIRED=1` to make that a failure. Rebuilding stops the staged widget extension as well
as the host, so macOS does not keep rendering old code.

`swift build` and the SwiftPM tests do not compile the extension. Check it separately with:

```sh
xcodebuild -project OpenUsageWidgets.xcodeproj -scheme OpenUsageWidgets \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

## Read the logs

OpenUsage logs through unified logging only, under the subsystem `OpenUsage`, one category per
subsystem tag (`refresh`, `cache`, `http`, `auth`, `updates`, `config`, `statusitem`, `lifecycle`,
`notifications`, and `plugin:<id>` and `auth:<id>` per account).

```sh
log stream --info --predicate 'subsystem == "OpenUsage"'
log stream --info --predicate 'subsystem == "OpenUsage" AND category == "refresh"'
log show --last 1h --info --predicate 'subsystem == "OpenUsage"'
```

macOS keeps info lines in memory only, so `log show` finds them for a few minutes at most. Each
refresh pass's `batch start` and `batch end` lines are notices, which it writes to disk, so this lists
every pass after the fact:

```sh
log show --last 2h --predicate 'subsystem == "OpenUsage" AND category == "refresh"'
```

Console.app shows the same lines; filter by subsystem. Debug-level lines exist in debug builds only
(`CONFIG=debug ./script/build_and_run.sh`) and need `--debug` instead of `--info`.

The HTTP transport logs one line per exchange: method, host and path, status, and duration. It never
logs a URL's query, a header, or a response body. Every message also passes `LogRedaction` before it
is written, which masks tokens, keys, `account=` values, and home paths.

## Tests

```sh
script/test_quiet.sh
script/test_quiet.sh --filter CursorTokenRefreshTests
```

The script runs the suite niced without letting it take the keyboard or show a window, and fails the
run if a test process ever came to the front.
