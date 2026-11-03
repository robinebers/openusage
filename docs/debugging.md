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
```

The script runs the suite niced, keeps it from taking the keyboard or the screen, and fails the run if
a test process came to the front.
