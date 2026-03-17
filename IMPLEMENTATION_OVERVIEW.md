# OpenUsage CLI Binary — Implementation Overview

## Goal
Standalone CLI binary that reuses the existing plugin engine to probe AI coding subscription providers and output usage data in a ccusage-style table (default) or JSON (for LLM agent tool consumption).

## Approach: Cargo Workspace + Shared Library Crate

Extracted `plugin_engine` into a shared crate (`crates/plugin-engine`), then created a CLI binary crate (`crates/openusage-cli`) that depends on it. The Tauri app re-exports the shared crate to keep all existing `crate::plugin_engine::` references working.

## File Structure

```
openusage/
  Cargo.toml                          # Workspace root
  crates/
    plugin-engine/
      Cargo.toml
      src/
        lib.rs                        # FROM src-tauri/src/plugin_engine/mod.rs
        manifest.rs                   # MOVED from src-tauri/src/plugin_engine/
        runtime.rs                    # MOVED (imports fixed)
        host_api.rs                   # MOVED
    openusage-cli/
      Cargo.toml
      src/
        main.rs                       # CLI entry point + arg parsing
        format_table.rs               # ccusage-style table formatter
        format_json.rs                # JSON output formatter
  src-tauri/
    Cargo.toml                        # MODIFIED: workspace member, dep on plugin-engine
    src/
      plugin_engine.rs                # NEW: replaces dir with `pub use openusage_plugin_engine::*;`
      lib.rs                          # UNCHANGED: imports work via re-export
```

## CLI Usage

```bash
# Default table output
openusage --plugins-dir ./plugins

# JSON output for LLM agents
openusage --plugins-dir ./plugins --json

# Filter to specific providers
openusage --plugins-dir ./plugins --provider claude --provider cursor
```

## CLI Flags

- `--json` — JSON output for LLM agents
- `--provider <id>` (repeatable) — filter to specific providers
- `--plugins-dir <path>` — plugins directory (default: `./plugins`)
- `--data-dir <path>` — app data directory (default: `~/.local/share/openusage/`)

## Verification

1. `cargo build -p openusage-cli` — CLI compiles
2. `cargo test -p openusage-plugin-engine -p openusage-cli` — 62 tests pass (41 + 21)
3. `./target/debug/openusage --plugins-dir ./plugins --provider mock` — table output works
4. `./target/debug/openusage --plugins-dir ./plugins --provider mock --json` — JSON output works
