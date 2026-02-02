2026-02-02

Goal
- Fix nested <button> hydration warning from TooltipTrigger usage.
- Raise per-file coverage to >=80% for flagged plugins and src files.

Scope
- UI: TooltipTrigger usage in PanelFooter and ProviderCard only.
- Tests: add/adjust unit/component tests to cover missing branches.

Non-Goals
- No new features; no API changes beyond markup/props.

Plan
1) Update TooltipTrigger to render Button directly (avoid nested button).
2) Adjust tooltip test mocks to support render prop.
3) Add tests for uncovered branches in plugins + App/provider-card/use-probe-events.
4) Run vitest coverage if feasible.
