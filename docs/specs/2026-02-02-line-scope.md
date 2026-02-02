# Line Scope API

**Date:** 2026-02-02
**Status:** Implemented

## Summary

Added required `scope` field to manifest lines to control visibility on Overview vs Detail pages.

## Schema

Each line in `plugin.json` must include a `scope` field:

```json
{ "type": "progress", "label": "Session", "scope": "overview" }
{ "type": "progress", "label": "Sonnet", "scope": "detail" }
```

## Values

| Value      | Behavior                                    |
|------------|---------------------------------------------|
| `overview` | Shown on Overview tab and detail pages      |
| `detail`   | Shown only on plugin detail pages           |

## Files Changed

- `src/lib/plugin-types.ts` - Added `scope` to `ManifestLine` type
- `src-tauri/src/plugin_engine/manifest.rs` - Added `scope` field to Rust struct
- `src/components/provider-card.tsx` - Added `scopeFilter` prop with filtering logic
- `src/pages/overview.tsx` - Passes `scopeFilter="overview"`
- `src/pages/provider-detail.tsx` - Passes `scopeFilter="all"`
- `plugins/*/plugin.json` - All plugin manifests updated with scope values
- `docs/plugins/schema.md` - Documentation updated

## Plugin Scope Assignments

### Claude
- `overview`: Session, Weekly
- `detail`: Sonnet, Extra usage

### Codex
- `overview`: Session, Weekly
- `detail`: Reviews, Credits

### Cursor
- `overview`: Plan usage
- `detail`: On-demand
