# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenUsage is a macOS menu bar application for tracking AI service usage (Claude, Cursor, Copilot, etc.). Built entirely with AI assistance using Tauri 2.x (Rust backend) + React 19 + TypeScript (frontend) with a QuickJS-based plugin system for provider integrations.

**Package Manager**: Bun (not npm/yarn)
**Platform**: macOS (Apple Silicon & Intel), with Windows/Linux planned
**UI**: Tailwind CSS 4.1 + shadcn/ui components
**Testing**: Vitest + React Testing Library (80% coverage requirement per file)

## Essential Commands

### Development
```bash
bun install                # Install dependencies
bun tauri dev              # Start development (bundles plugins + runs app)
bun run dev                # Vite dev server only (frontend preview)
bun run bundle:plugins     # Copy bundled plugins to resources
```

### Testing
```bash
bun run test                          # Run all tests
bun run test:watch                    # Watch mode
bun run test:coverage                 # Generate coverage report
bun run test src/path/to/file.test.tsx  # Run single test file
```

Coverage thresholds: 80% (branches, lines, functions, statements) per file. Tests run in CI on PRs.

### Building
```bash
bun run build              # TypeScript compile + Vite build (frontend)
bun run build:release      # Full release build (creates DMG for macOS)
bun tauri build            # Tauri build (creates app bundle)
```

### CLI Usage
```bash
openusage --provider=claude    # Query provider from terminal
openusage --help               # Show CLI help
```

## Architecture

### Three-Layer Design

1. **UI Layer** (`/src`): React/TypeScript
   - `App.tsx`: Main component managing global state, panel positioning, probe batching, tray updates
   - `components/`: Reusable components (provider-card, side-nav, ui/shadcn components)
   - `pages/`: Route-level views (overview, provider-detail, settings)
   - `hooks/`: Custom hooks (use-probe-events, use-app-update, use-dark-mode)
   - `lib/`: Utilities, types, settings management, analytics

2. **Application Layer** (`/src-tauri/src`): Rust/Tauri
   - `lib.rs`: Main setup, Tauri command handlers, plugin initialization
   - `cli.rs`: Terminal mode implementation
   - `panel.rs`: macOS panel management (via tauri-nspanel)
   - `tray.rs`: System tray icon and menu
   - `plugin_engine/`: QuickJS runtime and plugin execution

3. **Plugin Layer** (`/plugins/<id>/`): JavaScript in QuickJS sandbox
   - `plugin.json`: Manifest (metadata, output schema, brand colors)
   - `plugin.js`: Implementation (exports `probe(ctx)` function)
   - `icon.svg`: Provider icon (must use `currentColor`)
   - `plugin.test.js`: Tests (optional but recommended)

### Plugin System Architecture

**Execution Flow**:
1. Auto-update timer fires or user clicks refresh
2. Frontend calls `start_probe_batch()` Tauri command
3. Backend spawns blocking task per enabled plugin
4. Creates fresh QuickJS sandbox (no shared state between probes)
5. Injects host API (`ctx.host.*`) and utilities
6. Evaluates plugin script and calls `probe(ctx)`
7. Validates output against manifest schema
8. Emits `probe:result` event to frontend
9. Frontend updates UI with new data

**Host API** (`ctx.host.*` in plugin code):
- **Filesystem**: `fs.exists()`, `fs.readText()`, `fs.writeText()`
- **HTTP**: `http.request()` with configurable timeout
- **Environment**: `env.get()` (whitelisted: CODEX_HOME, ZAI_API_KEY, GLM_API_KEY)
- **Logging**: `log.info()`, `log.warn()`, `log.error()`
- **Keychain**: `keychain.readGenericPassword()` (macOS only)
- **SQLite**: `sqlite.query()` (read-only), `sqlite.exec()` (read-write)
- **Line builders**: `line.text()`, `line.progress()`, `line.badge()`
- **Formatters**: `fmt.planLabel()`, `fmt.resetIn()`, `fmt.dollars()`, `fmt.date()`
- **Utilities**: `util.toIso()`, `util.tryParseJson()`, `util.request()`, `util.retryOnceOnAuth()`, etc.

See `/docs/plugins/api.md` for complete host API reference.

### Key Patterns & Conventions

**Tauri IPC**:
- Frontend uses camelCase (e.g., `startProbeBatch`)
- Tauri auto-converts to snake_case (e.g., `start_probe_batch`)
- Events flow from Rust → React via `listen()`

**Plugin Sandboxing**:
- Each probe runs in fresh QuickJS runtime (isolated environment)
- No access to Node.js APIs or filesystem outside host API
- Plugins throw strings (not Error objects) for user-friendly error messages
- Sync and async (Promise-based) probe functions supported

**Error Handling**:
- Plugin errors display as error badges in UI (no crashes)
- Runtime creates fallback output on plugin failure
- Use `log.error()` in plugins for debugging (appears in app logs)

**Settings Persistence**:
- Tauri Store plugin for JSON-based settings
- Settings synced reactively between UI and backend
- Default settings applied on first run

**Testing Requirements** (from CONTRIBUTING.md):
- 80% coverage per file (enforced in CI)
- Test both success and error paths
- Mock Tauri APIs in tests (see `src/test/setup.ts`)
- Frontend: component tests next to source files
- Backend: Rust unit tests in `#[cfg(test)]` blocks
- Plugins: JavaScript tests in plugin directories

## Important Files & Directories

**Plugin Engine** (`/src-tauri/src/plugin_engine/`):
- `mod.rs`: Plugin discovery and loading (dev vs production paths)
- `manifest.rs`: `plugin.json` validation and icon loading
- `runtime.rs`: QuickJS sandbox creation and execution (1000+ lines)
- `host_api.rs`: Host API implementation (1584 lines)

**Core Components**:
- `src/App.tsx`: Main application logic (1000+ lines)
- `src/components/provider-card.tsx`: Provider display component
- `src/lib/settings.ts`: Settings management and defaults
- `src/lib/plugin-types.ts`: TypeScript types for plugin data

**Documentation**:
- `CONTRIBUTING.md`: Contribution guidelines (high quality bar, no AI commit messages)
- `AGENTS.md`: AI agent protocol and development guidelines
- `/docs/plugins/api.md`: Host API reference for plugin developers
- `/docs/plugins/schema.md`: Plugin structure and manifest format
- `/docs/providers/`: Individual provider documentation

## Development Notes

**macOS-Specific Features**:
- Uses `tauri-nspanel` for native panel management
- System tray integration with custom icon rendering
- Prevents WebView suspension and App Nap for background operation

**Auto-Update System**:
- Built-in updater with configurable intervals (5/15/30/60 minutes)
- Version checking against GitHub releases
- User-configurable auto-install preference

**Global Shortcuts**:
- Customizable keyboard shortcut to toggle panel
- Managed via Tauri global-shortcut plugin

**Analytics**:
- Event tracking via @aptabase/tauri
- Used for understanding feature usage (privacy-preserving)

**Git Workflow**:
- Merge directly to `main` branch (no staging)
- Use tagged releases for stability
- Commit messages: follow conventional commits, no AI-generated messages
- Always give co-credit in commits:
  ```
  <commit message>

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  ```

## Plugin Development

When creating a new plugin:

1. Create directory: `plugins/<provider-id>/`
2. Create `plugin.json` manifest with metadata and output schema
3. Implement `plugin.js` with `probe(ctx)` function
4. Add `icon.svg` (must use `currentColor` for theming)
5. Write tests in `plugin.test.js`
6. Document in `/docs/providers/<provider-id>.md`
7. Run `bun run bundle:plugins` to include in build

**Plugin Structure**:
```javascript
globalThis.__openusage_plugin = {
  id: "provider-id",  // Must match manifest
  probe: function(ctx) {
    // Access ctx.host.* APIs
    // Return { plan: "Pro", lines: [...] }
  }
}
```

**Output Schema** (in `plugin.json`):
```json
{
  "lines": [
    { "type": "text", "label": "Plan", "scope": "overview" },
    { "type": "progress", "label": "Usage", "scope": "detail", "primaryOrder": 1 }
  ]
}
```

See `/docs/plugins/schema.md` for complete schema documentation.

## Debugging

**Development Console**:
- Open DevTools in Tauri dev mode (right-click → Inspect)
- Console logs forwarded from React to Tauri logs

**Plugin Debugging**:
- Use `ctx.host.log.info()` in plugin code
- Logs appear in Tauri console and app logs
- Check `~/Library/Logs/openusage/` for persistent logs

**Tray Menu**:
- Debug Level submenu to adjust log verbosity
- "Show Stats" to open panel
- "Quit" to exit application

**Common Issues**:
- Plugin not loading: Check `plugin.json` validation errors in logs
- HTTP errors: Verify API keys in environment or keychain
- SQLite errors: Check database file paths and permissions
- Panel positioning: Ensure macOS accessibility permissions granted
