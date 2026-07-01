# OpenCode Go

Tracks OpenCode Go quota quotas exposed by the local `127.0.0.1:6736/v1/usage` usage source OpenUsage reads.

## What it tracks

| Metric | Meaning |
|---|---|
| Kimi for Coding | Kimi-for-coding quota usage (percentage) |
| GLM | GLM OpenCode Go quota usage (percentage) |

## Where data comes from

OpenUsage does not ask for any API token for OpenCode Go.
It reads usage from the first source available:

1. Local JSON files (in order):
   - `~/.config/opencodego/usage.json`
   - `~/.config/opencode/usage.json`
   - `~/.opencodego/usage.json`
   - `~/Library/Application Support/opencodego/usage.json`
   - `~/Library/Application Support/OpenCodeGo/usage.json`
2. Optional local endpoint set in one of:
   - `OPENCODEGO_USAGE_ENDPOINT`
   - `OPENCODE_GO_USAGE_ENDPOINT`

If no file and no valid endpoint are available, the provider shows:
**"No usage data"** with a local-source error.

## Setup

1. Install and run OpenCode Go on the same Mac so it writes quota usage to one of the local files above,
   or expose it through an HTTP endpoint on the local machine.
2. OpenUsage will show the metrics automatically on the next refresh.

## Under the hood

The parser is shape-tolerant and accepts mixed payloads:

- `quotas`, `limits`, `usage`, `metrics` arrays or dictionaries
- mixed numeric field names (`used`, `used_percent`, `currentValue`, `max`, `remaining`, `total`, `quota`)
- mixed timestamp formats used by local implementations

The payload is normalized to separate rows for the two tracked labels:

- rows containing "kimi" and "coding" map to **Kimi for Coding**
- rows containing "glm" map to **GLM**

## Notes on zero values

`0` values are valid:

- `used_percent: 0` is shown as `0%`.
- `$0.00`-style balance values are not treated as missing.

## Z.ai duplication check

OpenUsage already tracks Z.ai’s GLM Coding Plan separately under the **Z.ai** provider
(Session / Weekly / Web Searches). OpenCode Go adds separate Kimi for Coding and GLM rows from
OpenCode Go's local quota source and does not duplicate those Z.ai rows.

## Troubleshooting

- **"No usage data"** — no local file / endpoint result matched quota rows yet. Confirm OpenCode Go is running and writing usage locally.
- **"No OpenCode Go usage data source found."** — check file permissions and whether the endpoint URL env var is set correctly.
