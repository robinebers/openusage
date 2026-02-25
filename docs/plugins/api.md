# Host API Reference

This document describes the host APIs available to plugins via the `ctx` object passed to `probe(ctx)`.

## Context Object

```typescript
type ProbeContext = {
  nowIso: string              // Current UTC time (ISO 8601)
  app: {
    version: string           // App version
    platform: string          // OS platform (e.g., "macos")
    appDataDir: string        // App data directory
    pluginDataDir: string     // Plugin-specific data dir (auto-created)
  }
  host: HostApi
}
```

### `ctx.nowIso`

Current UTC timestamp in ISO 8601 format (e.g., `2026-01-15T12:30:00.000Z`).

### `ctx.app`

Application metadata:

| Property        | Description                                             |
| --------------- | ------------------------------------------------------- |
| `version`       | App version string                                      |
| `platform`      | OS platform (e.g., `"macos"`, `"windows"`, `"linux"`)   |
| `appDataDir`    | App's data directory path                               |
| `pluginDataDir` | Plugin-specific data directory (auto-created on demand) |

The `pluginDataDir` is unique per plugin (`{appDataDir}/plugins_data/{pluginId}/`) and is automatically created when the plugin runs. Use it to store config files, cached data, or state.

## Logging

```typescript
host.log.info(message: string): void
host.log.warn(message: string): void
host.log.error(message: string): void
```

Logs are prefixed with `[plugin:<id>]` and written to the app's log output.

**Example:**

```javascript
ctx.host.log.info("Fetching usage data...")
ctx.host.log.warn("Token expires soon")
ctx.host.log.error("API request failed: " + error.message)
```

## Filesystem

```typescript
host.fs.exists(path: string): boolean
host.fs.readText(path: string): string   // Throws on error
host.fs.writeText(path: string, content: string): void  // Throws on error
```

### Path Expansion

- `~` expands to the user's home directory
- `~/foo` expands to `$HOME/foo`

### Error Handling

Both `readText` and `writeText` throw on errors. Always wrap in try/catch:

```javascript
try {
  const content = ctx.host.fs.readText("~/.config/myapp/settings.json")
  const settings = JSON.parse(content)
} catch (e) {
  ctx.host.log.error("Failed to read settings: " + String(e))
  throw "Failed to read settings. Check your config."
}
```

**Example: Persisting plugin state**

```javascript
const statePath = ctx.app.pluginDataDir + "/state.json"

// Read state
let state = { counter: 0 }
if (ctx.host.fs.exists(statePath)) {
  try {
    state = JSON.parse(ctx.host.fs.readText(statePath))
  } catch {
    // Use default state
  }
}

// Update and save state
state.counter++
ctx.host.fs.writeText(statePath, JSON.stringify(state, null, 2))
```

## Environment

```typescript
host.env.get(name: string): string | null
```

Reads an environment variable by name.

### Behavior

- Returns variable value as string when set
- Returns `null` when missing
- Variable must be whitelisted first in `src-tauri/src/plugin_engine/host_api.rs`
- Resolution order: current process env first, then a login+interactive shell lookup (macOS)
- Values may be cached for the app session; restart OpenUsage after changing shell config

### Example

```javascript
const codexHome = ctx.host.env.get("CODEX_HOME")
const authPath = codexHome
  ? codexHome.replace(/\/+$/, "") + "/auth.json"
  : "~/.config/codex/auth.json"
```

## HTTP

```typescript
host.http.request({
  method?: string,           // Default: "GET"
  url: string,
  headers?: Record<string, string>,
  bodyText?: string,
  timeoutMs?: number         // Default: 10000
}): {
  status: number,
  headers: Record<string, string>,
  bodyText: string
}
```

### Behavior

- **No redirects**: The HTTP client does not follow redirects (policy: none)
- **Throws on network errors**: Connection failures, DNS errors, and timeouts throw
- **No domain allowlist**: Any URL is allowed (for now)

### Example: GET request

```javascript
let resp
try {
  resp = ctx.host.http.request({
    method: "GET",
    url: "https://api.example.com/usage",
    headers: {
      "Authorization": "Bearer " + token,
      "Accept": "application/json",
    },
    timeoutMs: 5000,
  })
} catch (e) {
  throw "Network error. Check your connection."
}

if (resp.status !== 200) {
  throw "Request failed (HTTP " + resp.status + "). Try again later."
}

const data = JSON.parse(resp.bodyText)
```

### Example: POST request with JSON body

```javascript
const resp = ctx.host.http.request({
  method: "POST",
  url: "https://api.example.com/refresh",
  headers: {
    "Content-Type": "application/json",
  },
  bodyText: JSON.stringify({ refresh_token: token }),
  timeoutMs: 10000,
})
```

## Keychain (macOS only)

```typescript
host.keychain.readGenericPassword(service: string): string
```

Reads a generic password from the macOS Keychain.

### Behavior

- **macOS only**: Throws on other platforms
- **Throws if not found**: Returns the password string if found, throws otherwise

### Example

```javascript
let credentials = null

// Try file first, fall back to keychain
if (ctx.host.fs.exists("~/.myapp/credentials.json")) {
  credentials = JSON.parse(ctx.host.fs.readText("~/.myapp/credentials.json"))
} else {
  try {
    const keychainValue = ctx.host.keychain.readGenericPassword("MyApp-credentials")
    credentials = JSON.parse(keychainValue)
  } catch {
    throw "Login required. Sign in to continue."
  }
}
```

## SQLite

### Query (Read-Only)

```typescript
host.sqlite.query(dbPath: string, sql: string): string
```

Executes a read-only SQL query against a SQLite database.

**Behavior:**

- **Read-only**: Database is opened with `-readonly` flag
- **Returns JSON string**: Result is a JSON array of row objects (must `JSON.parse()`)
- **Dot-commands blocked**: Commands like `.schema`, `.tables` are rejected
- **Throws on errors**: Invalid SQL, missing database, etc.

**Example:**

```javascript
const dbPath = "~/Library/Application Support/MyApp/state.db"
const sql = "SELECT key, value FROM settings WHERE key = 'token'"

let rows
try {
  const json = ctx.host.sqlite.query(dbPath, sql)
  rows = JSON.parse(json)
} catch (e) {
  ctx.host.log.error("SQLite query failed: " + String(e))
  throw "DB error. Check your data source."
}

if (rows.length === 0) {
  throw "Not configured. Update your settings."
}

const token = rows[0].value
```

### Exec (Read-Write)

```typescript
host.sqlite.exec(dbPath: string, sql: string): void
```

Executes a write SQL statement against a SQLite database.

**Behavior:**

- **Read-write**: Database is opened with full write access
- **Returns nothing**: Use for INSERT, UPDATE, DELETE, or other write operations
- **Dot-commands blocked**: Commands like `.schema`, `.tables` are rejected
- **Throws on errors**: Invalid SQL, missing database, permission denied, etc.

**Example:**

```javascript
const dbPath = "~/Library/Application Support/MyApp/state.db"

// Escape single quotes in value for SQL safety
const escaped = newToken.replace(/'/g, "''")
const sql = "INSERT OR REPLACE INTO settings (key, value) VALUES ('token', '" + escaped + "')"

try {
  ctx.host.sqlite.exec(dbPath, sql)
} catch (e) {
  ctx.host.log.error("SQLite write failed: " + String(e))
  throw "Failed to save token."
}
```

**Warning:** Be careful with SQL injection. Always escape user-provided values.

## Execution Timing

`probe(ctx)` is called when:

- The app loads
- The user clicks Refresh (per-provider retry button)
- The auto-update timer fires (configurable: 5/15/30/60 minutes)

Any token refresh logic (e.g., OAuth refresh) must run inside `probe(ctx)` at those times.

## Line Builders

Helper functions for creating output lines. All builders use an options object pattern.

### `ctx.line.text(opts)`

Creates a text line (label/value pair).

```typescript
ctx.line.text({
  label: string,      // Required: label shown on the left
  value: string,      // Required: value shown on the right
  color?: string,     // Optional: hex color for value text
  subtitle?: string   // Optional: smaller text below the line
}): MetricLine
```

**Example:**

```javascript
ctx.line.text({ label: "Account", value: "user@example.com" })
ctx.line.text({ label: "Status", value: "Active", color: "#22c55e", subtitle: "Since Jan 2024" })
```

### `ctx.line.progress(opts)`

Creates a progress bar line.

```typescript
ctx.line.progress({
  label: string,                    // Required: label shown on the left
  used: number,                     // Required: amount used (>= 0)
  limit: number,                    // Required: limit (> 0)
  format: {                         // Required: formatting rules
    kind: "percent" | "dollars" | "count",
    suffix?: string                 // Required when kind="count" (e.g. "credits")
  },
  resetsAt?: string | null,         // Optional: ISO timestamp for when usage resets
  periodDurationMs?: number,        // Optional: period length in ms for pace tracking
  color?: string,                   // Optional: hex color for progress bar
}): MetricLine
```

Notes:

- `used` may exceed `limit` (overages).
- For `format.kind: "percent"`, `limit` must be `100`.
- Prefer setting `resetsAt` (via `ctx.util.toIso(...)`) instead of putting reset info in other lines.
- `periodDurationMs`: when provided with `resetsAt`, enables pace visuals (Dot Pacing status + in-bar pace marker) and projected-rate messaging.

**Example:**

```javascript
ctx.line.progress({ label: "Usage", used: 42, limit: 100, format: { kind: "percent" } })
ctx.line.progress({ label: "Spend", used: 12.34, limit: 100, format: { kind: "dollars" } })
ctx.line.progress({
  label: "Session",
  used: 75,
  limit: 100,
  format: { kind: "percent" },
  resetsAt: ctx.util.toIso("2026-02-01T00:00:00Z"),
})
```

### `ctx.line.badge(opts)`

Creates a badge line (status indicator).

```typescript
ctx.line.badge({
  label: string,      // Required: label shown on the left
  text: string,       // Required: badge text
  color?: string,     // Optional: hex color for badge border/text
  subtitle?: string   // Optional: smaller text below the line
}): MetricLine
```

**Example:**

```javascript
ctx.line.badge({ label: "Plan", text: "Pro", color: "#000000" })
ctx.line.badge({ label: "Status", text: "Connected", color: "#22c55e" })
```

## Formatters

Helper functions for formatting values.

### `ctx.fmt.planLabel(value)`

Capitalizes a plan name string.

```javascript
ctx.fmt.planLabel("pro")        // "Pro"
ctx.fmt.planLabel("team_plan")  // "Team_plan"
```

### `ctx.fmt.resetIn(seconds)`

Formats seconds until reset as human-readable duration.

```javascript
ctx.fmt.resetIn(180000)  // "2d 2h"
ctx.fmt.resetIn(7200)    // "2h 0m"
ctx.fmt.resetIn(300)     // "5m"
ctx.fmt.resetIn(30)      // "<1m"
```

### `ctx.fmt.dollars(cents)`

Converts cents to dollars.

```javascript
ctx.fmt.dollars(1234)  // 12.34
ctx.fmt.dollars(500)   // 5
```

### `ctx.fmt.date(unixMs)`

Formats Unix milliseconds as short date.

```javascript
ctx.fmt.date(1704067200000)  // "Jan 1"
```

## Utilities

### `ctx.util.toIso(value)`

Normalizes a timestamp into an ISO string (or returns `null` if the input can't be parsed).

Accepts common inputs like:

- ISO strings (with or without timezone; timezone-less is treated as UTC)
- Unix seconds / milliseconds (number or numeric string)
- `Date` objects

**Example:**

```javascript
ctx.line.progress({
  label: "Weekly",
  used: 24,
  limit: 100,
  format: { kind: "percent" },
  resetsAt: ctx.util.toIso(data.resets_at),
})
```

## ccusage (Token Usage)

```typescript
host.ccusage.query(opts: {
  provider?: "claude" | "codex", // Optional; defaults to plugin id, then "claude"
  since?: string,                // Start date (YYYYMMDD or YYYY-MM-DD)
  until?: string,                // End date (YYYYMMDD or YYYY-MM-DD)
  homePath?: string,             // Provider home override (CLAUDE_CONFIG_DIR or CODEX_HOME)
  claudePath?: string,           // Legacy Claude-only override (deprecated; use homePath)
}):
  | { status: "ok", data: { daily: DailyUsage[] } }
  | { status: "no_runner" }
  | { status: "runner_failed" }
```

Queries local token usage via provider-specific ccusage CLIs:

- Claude: [`ccusage`](https://github.com/ryoppippi/ccusage)
- Codex: [`@ccusage/codex`](https://www.npmjs.com/package/@ccusage/codex)

Returns a status envelope:

- `ok`: query succeeded, usage data is in `data.daily`
- `no_runner`: no package runner (`bunx/pnpm/yarn/npm/npx`) was found
- `runner_failed`: at least one runner was available but all attempts failed

### Behavior

- **Runtime runners**: Executes pinned `ccusage@18.0.8` (Claude) or `@ccusage/codex@18.0.8` (Codex) via fallback chain `bunx -> pnpm dlx -> yarn dlx -> npm exec -> npx`
- **Provider-aware**: Resolves provider from `opts.provider` or plugin id (`claude`/`codex`)
- **No provider API calls**: Usage is computed from local JSONL session files; the host does not call Claude/Codex (or other provider) APIs, but package runners may contact a package registry to download the `ccusage` CLI if it is not already available locally
- **Graceful degradation**: returns `no_runner` when no runner exists, `runner_failed` when execution fails
- **Pricing**: Uses ccusage's built-in LiteLLM pricing data

### DailyUsage

The host normalizes only the top-level shape to `{ daily: [...] }`. Inner day fields come from the selected CLI and may differ by provider/version.

Commonly observed fields include:

| Property             | Type            | Notes |
| -------------------- | --------------- | ----- |
| `date`               | `string`        | Date label from CLI output (provider/locale-dependent) |
| `inputTokens`        | `number`        | Present in Claude and Codex |
| `outputTokens`       | `number`        | Present in Claude and Codex |
| `cacheCreationTokens`| `number`        | Claude field |
| `cacheReadTokens`    | `number`        | Claude field |
| `cachedInputTokens`  | `number`        | Codex field |
| `totalTokens`        | `number`        | Present in current Claude/Codex outputs |
| `totalCost`          | `number \| null`| Claude cost field |
| `costUSD`            | `number`        | Codex cost field |

### Example

```javascript
var result = ctx.host.ccusage.query({ provider: "codex", since: "20260101" })
if (result.status === "ok") {
  for (var i = 0; i < result.data.daily.length; i++) {
    var day = result.data.daily[i]
    var cost = day.totalCost != null ? day.totalCost : day.costUSD
    ctx.host.log.info(day.date + ": " + (day.totalTokens || 0) + " tokens, $" + (cost != null ? cost : "n/a"))
  }
} else if (result.status === "no_runner") {
  ctx.host.log.warn("ccusage unavailable: no package runner found")
}
```

## See Also

- [Plugin Schema](./schema.md) - Plugin structure, manifest format, and output schema
