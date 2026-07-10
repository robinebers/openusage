# OpenUsage Shell ↔ Core IPC Protocol (Windows spike)

Transport: Windows named pipe, newline-delimited JSON (one object per line, UTF-8).

## Pipe name

```
\\.\pipe\OpenUsageCore-<username>
```

`<username>` is `ProcessInfo.processInfo.userName` on the sidecar and `Environment.UserName` in the shell.

## Security

The sidecar creates the pipe with a DACL granting **GENERIC_ALL** to **SYSTEM** and the **current user SID** only (`ou_pipe_create_user_restricted` in `Win32Shim`). Other users cannot connect.

## Version

Protocol version **1** (returned in `pong.version`). No negotiation handshake in the spike; future versions may add `{"op":"hello","version":1}`.

## Client → server

| `op` | Fields | Behavior |
|---|---|---|
| `ping` | — | Health check |
| `snapshot` | — | Return cached provider snapshots (no network) |
| `refresh` | `provider` optional: `claude` \| `codex` \| `cursor` \| `grok` \| `openrouter` \| `zai` \| `all` (default `all`) | Refresh one or all providers with credentials, then return snapshot |

Example:

```json
{"op":"ping"}
{"op":"snapshot"}
{"op":"refresh","provider":"cursor"}
{"op":"refresh","provider":"all"}
```

## Server → client

| `op` | Fields |
|---|---|
| `pong` | `version` (int) |
| `snapshot` | `providers` (array) |
| `error` | `message` (string) |

### Provider object

```json
{
  "id": "claude",
  "displayName": "Claude",
  "plan": "Max 5x",
  "credentialsFound": true,
  "status": "ok",
  "metricLines": [
    {"kind":"progress","label":"Session","display":"Session: 42%"},
    {"kind":"text","label":"Spend","display":"Spend: $1.23"}
  ],
  "error": null
}
```

`status` values:

- `no_credentials` — `hasLocalCredentials()` false
- `pending` — credentials found but not yet refreshed
- `ok` — successful refresh
- `error` — refresh failed (`error` carries category + message)

Percent meters encode **used** 0…100 in `display`. The shell maps them to macOS default **Left** (remaining) for the floating strip and flyout bars.

### Metric line

| `kind` | `display` format |
|---|---|
| `progress` | `label: used%` (percent) or `label: used/limit` |
| `text` | `label: value` |
| `badge` | `label: text` |
| `values` | `label: formatted values` |
| `chart` | `label: N days` (shell may omit chart stubs) |

**No secret tokens, cookies, or raw credential blobs appear in any field.**

## Session semantics

- One long-lived connection from the WPF shell; sequential accept/handle on the sidecar (blocking read).
- Multiple requests may be sent on one connection (request/response pairs).
- Shell launches sidecar, connects, sends `snapshot` on startup, `refresh` + `snapshot` on manual/periodic Refresh (5 minutes).

## Shell surfaces (UX)

| Surface | Role |
|---|---|
| Floating strip | Always-on-top metrics strip (drag to move; position persisted) |
| Tray icon | OpenUsage logo; click opens flyout |
| Flyout | Provider cards + Refresh / Launch at Login |

## Shell single-instance

Separate from the core pipe above:

| Mechanism | Name |
|---|---|
| Mutex | `Local\OpenUsageShell` |
| Activation pipe | `\\.\pipe\OpenUsageShell-<username>` |

Second shell launch sends `show\n` on the activation pipe and exits. Primary instance shows the flyout.
