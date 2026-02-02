2026-02-02

Goal
- Vitest + coverage with per-file >=80% for branches/lines/functions/statements.
- Include src + plugins; exclude only non-source artifacts.
- Add tests until thresholds pass.

Scope
- Unit/component tests only (no e2e).
- Mock Tauri + network.

Decisions
- Runner: Vitest.
- Env: jsdom.
- Coverage: v8 provider; reporters text/html/lcov.
- Include: src/**/*.{ts,tsx}, plugins/**/*.js.
- Exclude: css, d.ts, public, scripts, src-tauri (incl resources), assets/icons.

Plan
1) Add deps + Vitest config + setup + scripts.
2) Write tests for src + plugins to reach per-file 80%+.
3) Run bun test:coverage; iterate.
