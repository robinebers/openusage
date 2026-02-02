# Plugin Schema

Plugin structure, manifest format, output schema, and lifecycle.

## Architecture Overview

```
User triggers refresh
       |
Tauri command `run_plugin_probes(pluginIds?)`
       |
For each enabled plugin:
  -> Create fresh QuickJS sandbox
  -> Inject host APIs (`ctx.host.*`)
  -> Evaluate plugin.js
  -> Call `probe(ctx)`
  -> Parse returned `{ lines: MetricLine[] }`
       |
Return `PluginOutput[]` to frontend
       |
UI renders via ProviderCard component
```

Key points:

- Each probe runs in **isolated QuickJS runtime** (no shared state between plugins or calls)
- Plugins are **synchronous or Promise-based** (unresolved promises timeout)
- **No background scheduler** - only runs on app load and when user clicks Refresh

## Plugin Directory Layout

```
plugins/<id>/
  plugin.json    <- manifest (required)
  plugin.js      <- entry script (required)
  icon.svg       <- plugin icon (required)
```

Bundled plugins live under `src-tauri/resources/bundled_plugins/<id>/`.

## Manifest Schema (`plugin.json`)

```json
{
  "schemaVersion": 1,
  "id": "my-provider",
  "name": "My Provider",
  "version": "0.0.1",
  "entry": "plugin.js",
  "icon": "icon.svg",
  "lines": [
    { "type": "badge", "label": "Plan" },
    { "type": "progress", "label": "Usage" }
  ]
}
```

| Field           | Type   | Required | Description                                |
| --------------- | ------ | -------- | ------------------------------------------ |
| `schemaVersion` | number | Yes      | Always `1`                                 |
| `id`            | string | Yes      | Unique identifier (kebab-case recommended) |
| `name`          | string | Yes      | Display name shown in UI                   |
| `version`       | string | Yes      | Semver version                             |
| `entry`         | string | Yes      | Relative path to JS entry file             |
| `icon`          | string | Yes      | Relative path to SVG icon file             |
| `lines`         | array  | Yes      | Output shape used for loading skeletons    |

Validation rules:

- `entry` must be relative (not absolute)
- `entry` must exist within the plugin directory
- `id` must match `globalThis.__openusage_plugin.id`
- `icon` must be relative and point to an SVG file (use `fill="currentColor"` for theme compatibility)

## Output Shape Declaration

Plugins must declare their output shape in `plugin.json`. This enables the UI to render
loading skeletons instantly while probes execute asynchronously.

### Lines Array

| Field   | Type   | Required | Description                                  |
|---------|--------|----------|----------------------------------------------|
| `type`  | string | Yes      | One of: `text`, `progress`, `badge`          |
| `label` | string | Yes      | Static label shown in the UI for this line   |

Example:

```json
{
  "lines": [
    { "type": "badge", "label": "Plan" },
    { "type": "progress", "label": "Plan usage" },
    { "type": "text", "label": "Resets" }
  ]
}
```

## Entry Point Structure

Plugins must register themselves on the global object:

```javascript
globalThis.__openusage_plugin = {
  id: "my-provider",  // Must match manifest.id
  probe: function(ctx) { ... }
}
```

## Output Schema

`probe(ctx)` must return (or resolve to):

```javascript
{ lines: MetricLine[] }
```

### Line Types

```typescript
type MetricLine =
  | { type: "text"; label: string; value: string; color?: string; subtitle?: string }
  | { type: "progress"; label: string; value: number; max: number; unit?: "percent" | "dollars"; color?: string; subtitle?: string }
  | { type: "badge"; label: string; text: string; color?: string; subtitle?: string }
```

- `color`: optional hex string (e.g. `#22c55e`)
- `unit`: `"percent"` shows `X%`, `"dollars"` shows `$X.XX`
- `subtitle`: optional text displayed below the line in smaller muted text

### Text Line

Simple label/value pair.

```javascript
ctx.line.text({ label: "Account", value: "user@example.com" })
ctx.line.text({ label: "Status", value: "Active", color: "#22c55e", subtitle: "Since Jan 2024" })
```

### Progress Line

Shows a progress bar with optional formatting.

```javascript
ctx.line.progress({ label: "Usage", value: 42, max: 100, unit: "percent" })
// Renders: Usage [████████░░░░░░░░░░░░] 42%

ctx.line.progress({ label: "Spend", value: 12.34, max: 100, unit: "dollars" })
// Renders: Spend [█░░░░░░░░░░░░░░░░░░░] $12.34

ctx.line.progress({ label: "Session", value: 75, max: 100, unit: "percent", subtitle: "Resets in 6d 20h" })
// Renders: Session [███████████████░░░░░] 75%
//                                Resets in 6d 20h
```

### Badge Line

Status indicator with colored border.

```javascript
ctx.line.badge({ label: "Plan", text: "Pro", color: "#000000" })
ctx.line.badge({ label: "Status", text: "Connected", color: "#22c55e", subtitle: "Last sync 5m ago" })
```

## Error Handling

| Condition                  | Result                                        |
| -------------------------- | --------------------------------------------- |
| Plugin throws a string     | Error badge with that string                  |
| Plugin throws non-string   | Error badge with a generic fallback message   |
| Promise rejects            | Error badge                                   |
| Promise never resolves     | Error badge (timeout)                         |
| Invalid line type          | Error badge                                   |
| Missing `lines` array      | Error badge                                   |
| Non-finite progress values | Coerced to `value: -1, max: 0` (UI shows N/A) |

Prefer throwing short, actionable strings (not `Error` objects).

## Minimal Example

A complete, working plugin that fetches data and displays all three line types.

**`plugin.json`:**

```json
{
  "schemaVersion": 1,
  "id": "minimal",
  "name": "Minimal Example",
  "version": "0.0.1",
  "entry": "plugin.js",
  "icon": "icon.svg"
}
```

**`plugin.js`:**

```javascript
(function () {
  globalThis.__openusage_plugin = {
    id: "minimal",
    probe: function (ctx) {
      let resp
      try {
        resp = ctx.host.http.request({
          method: "GET",
          url: "https://httpbin.org/json",
          timeoutMs: 5000,
        })
      } catch (e) {
        throw "Request failed. Check your connection."
      }

      if (resp.status !== 200) {
        throw "Request failed (HTTP " + resp.status + "). Try again later."
      }

      let data
      try {
        data = JSON.parse(resp.bodyText)
      } catch {
        throw "Invalid JSON. Try again later."
      }

      return {
        lines: [
          ctx.line.badge({ label: "Status", text: "Connected", color: "#22c55e" }),
          ctx.line.progress({ label: "Usage", value: 42, max: 100, unit: "percent", subtitle: "Resets in 2d 5h" }),
          ctx.line.text({ label: "Fetched at", value: ctx.nowIso }),
        ],
      }
    },
  }
})()
```

## Best Practices

- Wrap all host API calls in try/catch
- Throw short, user-friendly strings (not raw exception objects)
- Use `ctx.app.pluginDataDir` for plugin-specific state/config
- Keep probes fast (users wait on refresh)
- Validate API responses before accessing nested fields

## See Also

- [Host API Reference](./api.md) - Full documentation of `ctx.host.*` APIs
