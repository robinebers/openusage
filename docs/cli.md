# OpenUsage CLI

A standalone command-line tool that probes AI coding subscription providers and reports usage data. Designed for terminal use and LLM agent tool consumption.

## What Data Is Shown

The CLI displays **account-level subscription usage** -- the same data you see in each provider's billing dashboard. This includes plan limits, rate-limit windows, credit balances, and billing cycle progress.

This is **not** local machine telemetry. Each plugin authenticates against the provider's API using credentials already present on your machine (OAuth tokens, API keys, keychain entries, local SQLite databases) and fetches your account's current usage state.

Examples of what providers report:

| Provider | What's tracked | Source |
|---|---|---|
| Claude | Session/weekly rate limits, extra usage credits | Anthropic OAuth API |
| Cursor | Plan spend vs included amount, on-demand budget | Cursor Connect RPC |
| Copilot | Premium interactions, chat/completion quotas | GitHub REST API |
| Windsurf | Prompt credits, flex credits per billing cycle | Local language server RPC |
| Gemini | Request counts per model tier | Google AI Studio API |

The data is always real-time (fetched on each run) and reflects your account's global state, not per-device usage.

## Installation

### Build from source

Requires [Rust](https://rustup.rs/) (edition 2024).

```bash
# Clone the repo
git clone https://github.com/nicepkg/openusage.git
cd openusage

# Build the CLI
cargo build -p openusage-cli --release

# Binary is at:
./target/release/openusage

# Verify it works:
./target/release/openusage --plugins-dir ./plugins
```

Run the tests:

```bash
cargo test -p openusage-plugin-engine -p openusage-cli
```

Optionally copy to your PATH:

```bash
cp ./target/release/openusage ~/.local/bin/
```

## Usage

```
openusage [COMMAND] [OPTIONS]
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--plugins-dir <PATH>` | `./plugins` | Path to the plugins directory |
| `--data-dir <PATH>` | `~/.local/share/openusage/` | Path to app data directory (plugin state, cached tokens) |
| `--provider <ID>` | *(all)* | Filter to a specific provider; repeatable |
| `--json` | *(off)* | Output JSON instead of table |
| `--verbose, -v` | *(off)* | Enable verbose debug logging |
| `--help` | | Show help |

### Environment

Set `RUST_LOG` to control log verbosity (default: `warn`):

```bash
RUST_LOG=info openusage --plugins-dir ./plugins
```

## Commands

### Default (no command)

When run without a subcommand, `openusage` probes your configured providers and displays usage data.

On first run (no `~/.openusage/settings.json`), an interactive setup wizard launches to help you select and configure providers.

### `openusage setup`

Re-run the interactive provider setup. This **replaces** your current provider list (does not append).

### `openusage add <provider>`

Add a single provider to your configuration. Runs the same install/auth checks as initial setup.

### `openusage remove <provider>`

Remove a provider from your configured list. Does not uninstall anything.

### `openusage list`

Display your currently configured providers.

## Configuration

Settings are stored in `~/.openusage/`:

```
~/.openusage/
  settings.json       # Provider list
  env/
    keys.json         # API keys for env-var providers
```

`settings.json` stores which providers to probe on each run:
```json
{
  "providers": ["claude", "copilot", "gemini"]
}
```

`keys.json` stores API keys for providers that authenticate via environment variables (e.g., MiniMax, Z.ai):
```json
{
  "minimax": {
    "key": "sk-...",
    "keyName": "production"
  }
}
```

## Output Formats

### Table (default)

The default output is a terminal-friendly table with Unicode progress bars.

```
 Provider   Plan       Metric              Usage
──────────────────────────────────────────────────────────────────────
 Claude     Max (5x)   Session             ████████░░  80%
                        Weekly              ██████░░░░  60%
                        Extra usage spent   ██░░░░░░░░  $12.50 / $50.00
 Cursor     Pro        Total usage         ████░░░░░░  40%
                        On-demand           ░░░░░░░░░░  $0.00 / $100.00
 Copilot    Pro        Premium             ████████░░  80%
                        Chat                ██████████  95%
```

Progress bars use `█` (filled) and `░` (empty), 10 characters wide. The usage column shows the value in the format declared by the plugin:

- **Percent:** `80%`
- **Dollars:** `$12.50 / $50.00`
- **Count:** `150/500 requests`

Text and badge lines display their value directly:

```
 Provider   Plan       Metric     Usage
─────────────────────────────────────────────────────
 Claude     Max (5x)   Status     Active
                        Today      1.5M tokens - $0.75
```

Providers that fail to authenticate are excluded from output (no error rows clutter the table).

### JSON (`--json`)

For LLM agent consumption, use `--json` to get structured output:

```bash
openusage --plugins-dir ./plugins --json
```

```json
{
  "providers": [
    {
      "providerId": "claude",
      "displayName": "Claude",
      "plan": "Max (5x)",
      "lines": [
        {
          "type": "progress",
          "label": "Session",
          "used": 80.0,
          "limit": 100.0,
          "format": { "kind": "percent" },
          "resetsAt": "2026-03-17T18:00:00Z",
          "periodDurationMs": 18000000,
          "color": null
        },
        {
          "type": "text",
          "label": "Today",
          "value": "1.5M tokens - $0.75",
          "color": null,
          "subtitle": null
        }
      ]
    }
  ]
}
```

The JSON output:
- Wraps all results in `{ "providers": [...] }`
- Strips `iconUrl` (base64 SVG noise not useful for agents)
- Omits `plan` key entirely when null (not `"plan": null`)
- Preserves the full line schema including `resetsAt`, `periodDurationMs`, and `color`

### Line types in JSON

| Type | Fields | Description |
|---|---|---|
| `progress` | `label`, `used`, `limit`, `format`, `resetsAt?`, `periodDurationMs?`, `color?` | Numeric usage with progress semantics |
| `text` | `label`, `value`, `color?`, `subtitle?` | Key-value information |
| `badge` | `label`, `text`, `color?`, `subtitle?` | Status indicator |

### Format kinds

| Kind | `used`/`limit` meaning | Example |
|---|---|---|
| `percent` | Percentage (limit always 100) | `used: 80, limit: 100` -> 80% |
| `dollars` | Dollar amounts | `used: 12.50, limit: 50.00` -> $12.50 / $50.00 |
| `count` | Numeric with suffix | `used: 150, limit: 500, suffix: "requests"` -> 150/500 requests |

## Examples

```bash
# Show all configured providers
openusage --plugins-dir ./plugins

# Show only Claude usage
openusage --plugins-dir ./plugins --provider claude

# Show Claude and Cursor
openusage --plugins-dir ./plugins --provider claude --provider cursor

# JSON for piping to jq or an LLM agent
openusage --plugins-dir ./plugins --json | jq '.providers[].displayName'

# Run interactive setup
openusage setup

# Add a single provider
openusage add claude

# Remove a provider
openusage remove cursor

# List configured providers
openusage list

# Show usage with verbose logging
openusage -v
```

## Troubleshooting

**"plugins directory not found"** -- Point `--plugins-dir` to the `plugins/` directory in the repo root.

**Provider missing from output** -- The provider likely failed to authenticate. Run with `RUST_LOG=info` to see plugin log output. Most plugins require the corresponding app to be logged in (e.g., Claude Code, Cursor, `gh auth login` for Copilot).

**Empty output** -- No providers authenticated successfully. Check that at least one provider's credentials are available on this machine.

**"First run shows setup wizard"** -- This is expected. Select your providers and follow the prompts.

**"Provider missing after setup"** -- The provider may have failed install or auth checks during setup. Run `openusage add <provider>` to retry.

## Architecture

The CLI reuses the same plugin engine as the OpenUsage desktop app. Plugins are JavaScript files that run in isolated QuickJS sandboxes. Each plugin's `probe()` function authenticates against its provider's API and returns structured usage data.

```
CLI main.rs
  -> loads plugins from --plugins-dir
  -> injects env keys from ~/.openusage/env/keys.json
  -> runs probes in parallel (std::thread::scope)
  -> filters out auth failures
  -> formats as table or JSON
```

The plugin engine (`crates/plugin-engine`) is a shared Rust crate used by both the CLI and the Tauri desktop app.

## Plugin Authoring: CLI Metadata

Plugins can declare CLI-specific metadata in their `plugin.json` manifest under the optional `cli` key:

```json
{
  "cli": {
    "category": "cli",
    "binaryName": "claude",
    "installCmd": "curl -fsSL https://claude.ai/install.sh | sh",
    "loginCmd": "claude auth login"
  }
}
```

### Fields

| Field | Required | Description |
|---|---|---|
| `category` | yes | One of: `cli` (CLI tool), `ide` (desktop IDE), `env` (API key via env var), `demo` (testing only) |
| `binaryName` | cli only | Binary name to check on PATH (e.g., `claude`, `gh`) |
| `installCmd` | no | Shell command to install the tool (Ubuntu). Shown to user for approval before execution. |
| `loginCmd` | no | Shell command to authenticate (e.g., `claude auth login`) |
| `envVarNames` | env only | Array of environment variable names the plugin reads (e.g., `["MINIMAX_API_KEY"]`) |
| `envKeyLabel` | env only | Human-readable label for the API key prompt (e.g., `"MiniMax API Key"`) |

The `cli` field is optional -- plugins without it are still loaded by the desktop app but cannot be configured via the CLI setup flow.
