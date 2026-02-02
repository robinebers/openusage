2026-02-02
- Coverage provider: v8 (Vitest default).
- Test environment: jsdom.
- Coverage reporters: text, html, lcov.
- Coverage include: src/**/*.{ts,tsx}, plugins/**/*.js.
- Coverage exclude: **/*.d.ts, **/*.css, public/**, scripts/**, src-tauri/**, src-tauri/resources/**, src-tauri/icons/**.
- Tooltip disabled state uses TooltipTrigger render + span wrapper to avoid nested buttons while keeping hover tooltips.
- Mock/cursor lineProgress now always include unit/color fields to remove branchy conditionals (no change when values are defined).
- Mock plugin treats non-string mode as unknown; display uses safeString for visibility in warnings.
- Committed generated `coverage/` output per user request.
