# Logging

OpenUsage keeps a file log so you can capture what the app was doing and share it with support when
something misbehaves. Lines at or above your chosen level also go to the macOS unified log, so raising
the level to Debug surfaces the extra detail in both places (see [Debugging](debugging.md) for
`log stream`).

## Where the log file lives

```
~/Library/Logs/OpenUsage/OpenUsage.log
```

The easiest way to grab it: open Settings -> Advanced and use **Copy Log Path** (puts the path on the
clipboard) or **Reveal in Finder** (selects the file in a Finder window). No Terminal needed.

## Changing the log level (Settings -> Advanced)

The **Log Level** picker controls how much detail is written. Your choice persists across launches and
takes effect immediately — no restart.

| Level | What it captures |
|---|---|
| Error | Only failures. |
| Warning | Failures plus things that look wrong but recovered. |
| Info | The normal story: refresh start/end, per-provider results, cache and auth milestones. |
| Debug | Everything, including per-request and per-cache-check detail. |

The release default is **Info** — quiet but useful. **Debug** is opt-in; turn it on only while
reproducing a problem, since it is much noisier.

If a local usage log exists but cannot be read, OpenUsage writes one warning and skips it for that
refresh. It does not repeat the warning every five minutes; it warns again only if the file recovers
and later becomes unreadable again.

## Subsystem tags

Every line is prefixed with a bracketed tag so the log is easy to grep:

`[refresh]` `[cache]` `[http]` `[auth]` `[keychain]` `[menubar]` `[updates]` `[config]`
`[subprocess]` `[localapi]`, plus per-provider tags like `[plugin:claude]` and `[auth:claude]`.

For example, to follow just the refresh cycle:

```sh
grep '\[refresh\]' ~/Library/Logs/OpenUsage/OpenUsage.log
```

## What is never logged

Secrets never reach the log. Access/refresh tokens, cookies, session tokens, and API keys are redacted
before any line is written (a sensitive value becomes `first4...last4`, or `[REDACTED]` when too short
to mask safely), and filesystem paths under your home directory are replaced with `[PATH]`. Response
bodies are never logged in full; on an HTTP error the app may record a redacted, truncated (≤500 byte)
preview at Debug to aid diagnosis — run through the same redaction first. The redaction rules match the
original app's, and a test suite guards them.

## File size cap

The log is capped at ~10 MB. When it fills up, the current file is rotated to `OpenUsage.1.log` and a
fresh `OpenUsage.log` starts, so a long-running session can never fill your disk (at most ~20 MB across
the live file and one archive). An oversize file left over from a previous session is rotated once at
launch.

> Note: the dev build and a released build both write to the same `OpenUsage.log`. Running them at the
> same time interleaves their lines — fine for normal use, worth knowing if you debug both at once.
