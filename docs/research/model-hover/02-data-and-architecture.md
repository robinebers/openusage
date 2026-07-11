# Model Hover Panel: data and architecture feasibility

> **Historical / superseded.** This feasibility report is a 2026-07-04 preimplementation snapshot.
> The model-breakdown data path and spend-row hover panel described as proposed below shipped that
> day; see [Dashboard rows](../../dashboard.md#rows),
> [`SpendTileMapper.swift`](../../../Sources/OpenUsage/Providers/SpendTileMapper.swift),
> [`HoverPopoverState.swift`](../../../Sources/OpenUsage/Views/HoverPopoverState.swift), and
> [`ModelUsageDetail.swift`](../../../Sources/OpenUsage/Views/ModelUsageDetail.swift) for the current
> implementation. The analysis remains a historical record rather than current-state documentation;
> narrow implementation references may be corrected as the code evolves.

Research date: 2026-07-04. Scope: current `main`-line SwiftPM app architecture in this worktree. This is read-only technical research for a hover-revealed per-model spend/usage breakdown on the existing `Today`, `Yesterday`, and `Last 30 Days` spend rows.

> **Status update (2026-07-10):** This document records the preimplementation architecture at its research date. The current code now carries per-model usage through `ModelUsageSeries`; Cursor's boundary parser also throws on unusable CSV structure and returns `CursorUsageCSVParseResult` (`rows` plus `rejectedRowCount`). See [Cursor](../../providers/cursor.md) for current user-facing behavior.

## Executive conclusion

This feature is technically feasible for Cursor, Claude, Codex, and partially for Grok without adding new external usage APIs. The raw provider inputs already carry a model dimension before the current spend pipeline collapses them into `DailyUsageSeries`.

The main gap is structural: current spend rows only receive per-day totals (`DailyUsageEntry.date`, `totalTokens`, `costUSD`) plus unknown-model names. No `MetricLine`, `WidgetData`, or cached `ProviderSnapshot` currently carries the per-model rows needed by a hover panel.

Recommended shape: compute a provider-neutral per-day-per-model aggregate at the same time the existing scanners/CSV mapper compute `DailyUsageSeries`, pass it through `SpendTileMapper`, attach the period-scoped breakdown directly to the corresponding `MetricLine.values` for `Today`, `Yesterday`, and `Last 30 Days`, then render a SwiftUI hover popover from `WidgetRowView` for usage-period rows.

## Current spend data path

Shared spend tiles are produced in `Sources/OpenUsage/Providers/SpendTileMapper.swift`.

`SpendTileMapper.appendTokenUsage(_:to:now:estimated:unknownModelsByDay:)` appends three `.values` lines:

- `Today`
- `Yesterday`
- `Last 30 Days`

It consumes `DailyUsageSeries` from `Sources/OpenUsage/Models/DailyUsageSeries.swift`. That type is intentionally provider-neutral and contains only:

- `DailyUsageEntry.date`
- `DailyUsageEntry.totalTokens`
- `DailyUsageEntry.costUSD`

`LogUsageScan` adds only one extra side channel today:

- `series: DailyUsageSeries`
- `unknownModelsByDay: [String: Set<String>]`

That means current spend rows have enough data to show total cost/tokens and unknown pricing warnings, but not enough to show model-by-model totals.

The shared pricing engine is in `Sources/OpenUsage/Pricing/`:

- `ModelPricing.resolve(model:)` returns `ModelRates?`.
- `ModelPricing.estimatedCostDollars(model:tokens:)` prices a `TokenBreakdown`.
- `TokenBreakdown` carries `input`, `cacheWrite5m`, `cacheWrite1h`, `cacheRead`, `output`, and `isFast`.
- `ModelRates.costDollars(for:)` applies per-million rates, cache-write/cache-read rates, 1-hour cache-write pricing, above-200k tiers where present, and fast multipliers.
- `ModelPricingStore.current()` serves the freshest loaded pricing snapshot and starts a background refresh when a source is due; pricing source refresh is roughly daily.

## Provider data availability

### Cursor: high feasibility

Spend source today:

- `CursorProvider.appendSpendLines(to:accessToken:)` fetches `https://cursor.com/api/dashboard/export-usage-events-csv` through `CursorUsageClient.fetchUsageCSV(accessToken:start:end:)`.
- The query window starts 29 days before local start-of-today and ends at `now`, so it covers today plus the previous 29 calendar days.
- `CursorUsageCSV.parse(csv:pricing:)` parses the CSV into `[CursorUsageCSVRow]`.
- `CursorUsageMapper.appendSpendLines(rows:now:to:)` aggregates rows into `DailyUsageSeries`, then calls `SpendTileMapper.appendTokenUsage(... estimated: false ...)` and `appendUsageTrend(...)`.

Per-model data available before collapse:

- `CursorUsageCSVRow` in `Sources/OpenUsage/Providers/Cursor/CursorUsageCSV.swift` carries:
  - `date: Date`
  - `model: String`
  - `maxMode: Bool`
  - `tokens: TokenBreakdown`
  - `imputedCostDollars: Double?`
- The parser maps CSV columns `Model`, `Max Mode`, `Input (w/o Cache Write)`, `Input (w/ Cache Write)`, `Cache Read`, and `Output Tokens`.
- `imputedCostDollars` is already computed per row through `ModelPricing.estimatedCostDollars(model:tokens:)`.

Can build per-day-per-model aggregates with existing data:

- Yes. `CursorUsageMapper.appendSpendLines` currently loops all rows and groups only by day. It can also group by `(day, model)` in the same pass.
- Cost should follow the existing behavior: sum raw row costs and round once at the aggregate boundary, not per row. Current day totals round to cents after summing.
- Rows where `imputedCostDollars == nil` should still contribute tokens and should mark the model as unpriced/unknown for the hover panel. Existing unknown-model warnings already use this rule.
- `maxMode` is available if the UI wants to label variants later, though current cost imputation does not apply a separate Max Mode uplift because the CSV rows are aggregates.

Verdict: strongest starting point. Cursor already has row-level model, tokens, and cost before `DailyUsageSeries` is built.

### Claude: high feasibility

Spend source today:

- `ClaudeProvider.probe(state:)` calls `ClaudeLogUsageScanner.scan(now:pricing:)`.
- The scanner reads Claude Code local session logs under roots derived from `CLAUDE_CONFIG_DIR`, `$XDG_CONFIG_HOME/claude`, `~/.claude`, and Claude desktop Cowork local-agent-mode session directories.
- The log files are `<config dir>/projects/**/*.jsonl`.
- The scanner returns `LogUsageScan`, then `ClaudeProvider` calls `SpendTileMapper.appendTokenUsage(scan.series, ..., unknownModelsByDay: scan.unknownModelsByDay)` and `appendUsageTrend(...)`.

Per-model data available before collapse:

- `ClaudeLogUsageScanner.Entry` in `Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift` carries:
  - `timestamp: Date`
  - `tokens: TokenBreakdown`
  - `costUSD: Double?`
  - `model: String?`
  - dedup fields such as `messageID`, `requestID`, `isSidechain`, and `hasSpeed`
- `parseLine(_:)` reads `message.model`, maps `<synthetic>` to `nil`, parses input/output/cache token buckets, and carries `costUSD` when the log line provides it.
- `TokenBreakdown.isFast` is set from Claude's `usage.speed == "fast"`.
- `aggregate(entries:since:pricing:)` deduplicates entries first, then prices by event:
  - use carried `costUSD` when present
  - otherwise price `model + TokenBreakdown` through `ModelPricing`
  - unknown models contribute tokens and populate `unknownModelsByDay`

Can build per-day-per-model aggregates with existing data:

- Yes. The aggregate function already has deduplicated event-level `Entry` records with timestamp, model, token buckets, and cost source.
- The feature should extend or parallel `ClaudeLogUsageScanner.aggregate` before it collapses into `tokensByDay` and `costByDay`.
- Entries with `model == nil` can contribute to total daily spend/tokens today only if they carry `costUSD`; for a model panel they need an explicit display bucket such as `Unknown Model` or should be omitted with a note. Avoid hiding their tokens silently if totals would otherwise disagree.

Verdict: feasible with scanner aggregation changes only; no new API needed.

### Codex: high feasibility

Spend source today:

- `CodexProvider.probe(authState:)` calls `CodexLogUsageScanner.scan(now:pricing:)`.
- The scanner reads Codex CLI rollout/session logs from `CODEX_HOME` or `~/.codex`, including `sessions/` and `archived_sessions/`.
- It returns `LogUsageScan`, then `CodexProvider` calls `SpendTileMapper.appendTokenUsage(scan.series, ..., unknownModelsByDay: scan.unknownModelsByDay)` and `appendUsageTrend(...)`.

Per-model data available before collapse:

- `CodexLogUsageScanner.Event` in `Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift` carries:
  - `timestamp: Date`
  - `model: String`
  - `input: Int`
  - `cached: Int`
  - `output: Int`
  - `reasoning: Int`
  - `total: Int`
- `parseFile(_:)` tracks the current model from `turn_context` records, handles `token_count` events, and uses `resolveModel(...)` to:
  - use explicit model metadata when present
  - fall back to the current session model
  - fall back to `gpt-5` for early sessions without model metadata
  - map retired `codex-auto-review` to date-specific model fallbacks
- `aggregate(events:since:pricing:fastTier:)` deduplicates identical events across copied logs, groups by day, resolves rates per model, and prices with `CodexLogUsageScanner.cost(rates:event:fastTier:)`.

Can build per-day-per-model aggregates with existing data:

- Yes. `Event` has enough data to group by `(day, model)` and compute tokens/cost.
- The fast/priority service tier is account-wide for the scan, read from `config.toml`; the per-model aggregate must use the same `fastTier` flag and the same `cost(rates:event:fastTier:)` helper so totals match the existing spend tiles.
- The `reasoning` field is included in `total`, but current cost math charges `output` only. The report UI should be careful about token labels: either show total tokens to match the tile, or show an expanded input/cached/output/reasoning breakdown only if the cost rules are clear.

Verdict: feasible with scanner aggregation changes only; no new API needed.

### Grok: medium feasibility

Spend source today:

- `GrokProvider.probe(state:accessToken:)` calls `GrokLogUsageScanner.scan(daysBack:now:pricing:)`.
- The scanner reads one append-only log: `$GROK_HOME/logs/unified.jsonl` or `~/.grok/logs/unified.jsonl`.
- It returns `DailyUsageSeries?` directly, then `GrokProvider` calls `SpendTileMapper.appendTokenUsage(tokenUsage, ...)` and `appendUsageTrend(...)`.

Per-model data available before collapse:

- `GrokLogUsageScanner.parse(_:since:pricing:)` tracks `modelByPID: [Int: String]`.
- Model-change events come from messages such as:
  - `model changed`
  - `model catalog: notifying clients`
  - `backend_search: model switch`
  - `subagent model resolved`
- Token rows are `shell.turn.inference_done` lines. They include prompt/completion/reasoning/cache token counts but do not directly include the model id.
- The scanner attributes a token row to the current model for that process id, then prices it through `ModelPricing.estimatedCostDollars(...)`.

Can build per-day-per-model aggregates with existing data:

- Mostly yes, but weaker than the other providers.
- The current parser has the inferred model at the exact point it computes cost, so it can group by `(day, model)` before returning.
- It currently returns only `DailyUsageSeries`, not `LogUsageScan`, and it does not track `unknownModelsByDay`. Unknown or unattributed Grok rows contribute tokens but leave cost unpriced without naming the missing model in the UI.
- If a token row has no prior model event for its `pid`, the existing daily total still counts tokens but does not price the row. A model panel needs a clear `Unattributed` bucket or a note explaining that some tokens could not be tied to a model.

Verdict: feasible for rows with inferred model ids, but the first implementation should explicitly handle unattributed rows and add unknown-model tracking if Grok is included.

## Rendering path for spend rows

Metric identity:

- `WidgetDescriptor.spendTiles(provider:)` in `Sources/OpenUsage/Models/WidgetDescriptor+Factories.swift` declares the three spend descriptors:
  - `<provider>.today`
  - `<provider>.yesterday`
  - `<provider>.last30`
- Each descriptor is a `.combined(...)` row with `isUsagePeriod: true`.
- The descriptor `metricLabel` is the title: `Today`, `Yesterday`, or `Last 30 Days`.

Layout defaults:

- `DefaultLayout.metricIDs` enables spend rows for Claude, Codex, Cursor, and Grok.
- `DefaultLayout.expandedMetricIDs` places those spend rows below the provider caret by default.
- `DefaultLayout.pinnedMetricIDs` does not pin these rows by default.

Snapshot to view:

- Provider refreshes produce `ProviderSnapshot.lines: [MetricLine]`.
- `WidgetDataStore.data(for:)` resolves a `WidgetDescriptor` by looking up `snapshot.line(label: descriptor.metricLabel)`.
- For `.values` rows, `WidgetDataStore.resolve` copies raw `values`, `expiriesAt`, and `unknownModels` into `WidgetData`, then stamps:
  - global meter style
  - reset display mode
  - `alwaysShowPacing`
- `WidgetGroupedListView` resolves each row and renders `WidgetRowView(data: ...)`.

Current row structure:

- `WidgetRowView` has three row paths:
  - chart rows: `UsageSparkline(data:)`
  - bounded meter rows
  - unbounded text rows
- Spend rows are unbounded text rows.
- `unboundedRow` renders:
  - `labelColumn` with `data.title`
  - optional unknown-model warning icon
  - right-aligned `data.unboundedDetail`
  - optional subtitle
- Existing hover on spend rows is limited to:
  - value text `.hoverTooltip(data.unboundedValueTooltip)`
  - unknown-model warning icon `.hoverTooltip(data.unknownModelTooltip)`
- Labels intentionally have no tooltip: `WidgetData.unboundedLabelTooltip` returns `nil`.

## Existing hover and overlay patterns

`hoverTooltip`:

- Implemented in `Sources/OpenUsage/Views/HoverTooltip.swift`.
- It is a View modifier that shows text in a separate borderless, non-activating, click-through `NSPanel`.
- The comments explicitly say a SwiftUI overlay inside the popover would be clipped by the popover window and scroll view, so tooltips use a separate panel.
- The tooltip panel sits one level above `.popUpMenu`, does not become key/main, and is dismissed from `StatusItemController.hidePanel()` and `DashboardView.resetTransientState()`.

Usage trend hover:

- `UsageSparkline` in `Sources/OpenUsage/Views/UsageSparkline.swift` attaches hover only to the bar strip, not the whole row title.
- It uses `TrendHoverState` from `Sources/OpenUsage/Views/UsageTrendDetail.swift`:
  - 400ms reveal dwell
  - 180ms hide grace while moving from inline row to detail popover
  - dismissal on teardown
- It presents `UsageTrendDetail` through SwiftUI `.popover(isPresented:arrowEdge:)`.
- `UsageTrendDetail` has its own internal bar hover state for highlighting the hovered day.
- Tests in `Tests/OpenUsageTests/UsageTrendTests.swift` cover the open/close/quick-pass behavior.

Popover constraints:

- The app no longer relies on a stock `NSPopover`; `StatusItemController` owns a borderless non-activating `MenuBarPanel` (`NSPanel`) at `.popUpMenu` level.
- The panel is fixed width (`320`) and dynamic height. `DashboardView` measures content height and forwards it through `PanelHeightModifier` / `PanelHeightBridge`.
- `StatusItemController` opens the panel at a persisted/clamped height and applies SwiftUI-driven height morphs as content changes.
- A hover detail panel must not accidentally change the dashboard's measured content height unless that is intended. A SwiftUI `.popover` like the trend detail should not contribute to the main panel's content height, which is desirable here.
- A pure in-window overlay risks clipping in the scroll view and root panel, as documented in `HoverTooltip.swift`.

UI recommendation:

- Reuse the `UsageSparkline` / `TrendHoverState` pattern for the Models panel instead of `hoverTooltip`.
- Use `hoverTooltip` only for short text notes; the model breakdown is structured content and may need interaction/hover inside the panel, so it fits a SwiftUI `.popover` better.
- Hook the trigger at `WidgetRowView` for `data.isUsagePeriod && data.modelBreakdown != nil`, not in `WidgetGroupedListView`, because `WidgetRowView` owns the row layout and already handles chart-vs-bounded-vs-unbounded rendering.
- Make the hover target deliberate. The task says hovering the spend metric row should open the panel, but row-level hover may interfere with drag/reorder hit testing in `WidgetGroupedListView.row`. A practical compromise is to attach the hover to the unbounded row content shape inside `WidgetRowView` while preserving the existing drag gesture outside; test quick passes and drag starts.

## Caching and refresh behavior

Provider refresh cadence:

- `AppContainer.startPeriodicRefresh` calls `WidgetDataStore.refreshAll()` on launch and every `RefreshSetting.interval`.
- `RefreshSetting.interval` is fixed at 5 minutes.
- Manual refresh uses `dataStore.refreshAll(force: true)`.
- `WidgetDataStore.refresh(providerID:force:)` honors `ProviderSnapshotCache.snapshot(providerID:)` unless forced.
- `ProviderSnapshotCache` TTL is the same 5-minute interval.
- Snapshots loaded from disk display immediately but are not considered fresh for gating the first post-launch refresh.

Pricing refresh cadence:

- `ModelPricingStore.current()` is synchronous from the scanner's point of view and returns loaded pricing immediately.
- It starts a background refresh when sources are due.
- Pricing sources are refreshed roughly daily, with failed-source retry after 30 minutes.
- Scanners always price against the current loaded snapshot; they do not block on pricing network fetches.

Provider scanner computation:

- Claude and Codex scanners are actors with per-file parse caches keyed by path, size, and mtime. Every refresh reuses unchanged parsed entries/events and reruns dedup + aggregation.
- Cursor fetches the CSV on each provider refresh and parses rows in memory.
- Grok reads and parses the single unified log on each refresh; there is no per-file parse cache today.

Would a model breakdown require extra computation?

- Cursor: minimal. The rows are already parsed and priced. Add a second aggregation pass or extend the current pass.
- Claude: minimal-to-moderate. Deduped entries are already in memory; group them by `(day, model)` while aggregating.
- Codex: minimal-to-moderate. Deduped events are already in memory; group by `(day, model)` while aggregating and reuse the same cost function.
- Grok: moderate. The parser has the model during the line pass but currently throws it away. Add grouping in the same pass; consider whether to add caching if the log grows large.

Natural data ownership:

- The raw collection layer should not be the UI owner. It should emit provider-neutral model aggregates alongside day totals.
- `SpendTileMapper` is the best boundary for choosing which aggregate attaches to `Today`, `Yesterday`, and `Last 30 Days`, because it already owns period selection and unknown-model union behavior.
- `WidgetDataStore` should remain a resolver, not recompute aggregates from labels or raw provider data.

## Recommended data model

Add provider-neutral internal models near `DailyUsageSeries`:

- `ModelUsageEntry`
  - `model: String`
  - `totalTokens: Int`
  - `costUSD: Double?`
  - optional `inputTokens`, `cacheWriteTokens`, `cacheReadTokens`, `outputTokens` if the first UI wants token-bucket detail
  - optional `isUnpriced: Bool` or derive from `costUSD == nil`
- `DailyModelUsageEntry`
  - `date: String`
  - `models: [ModelUsageEntry]`
- `ModelUsageSeries`
  - `daily: [DailyModelUsageEntry]`

Or use a dictionary shape internally:

- `[String: [String: ModelUsageAccumulator]]`
- outer key: `yyyy-MM-dd`
- inner key: display/canonical model name

Then normalize to sorted arrays only at the mapper boundary.

Sorting should be deterministic:

- priced spend descending
- token count descending
- model display name ascending
- unpriced models should remain visible and not be folded into `Other`

Cost rounding:

- Preserve exact summed costs internally.
- Round to cents once per displayed model/period, matching Cursor's existing day-total strategy.
- The period total shown in the existing spend row must still match the sum of the existing daily path, not a separately rounded model sum.

Unknown/unattributed rows:

- Unknown priced source means "model is known but no rate exists". Show the model with tokens and no dollar cost, plus warning copy.
- Unattributed means "tokens could not be tied to a model" (mainly Grok, possibly Claude synthetic rows). Use a separate `Unattributed` bucket only if needed, and explain it in the panel note.

## Recommended integration point

Data path:

1. Extend `LogUsageScan` in `DailyUsageSeries.swift` to carry model aggregates, or introduce a sibling result type such as `SpendUsageScan`.
2. Update:
   - `ClaudeLogUsageScanner.aggregate(entries:since:pricing:)`
   - `CodexLogUsageScanner.aggregate(events:since:pricing:fastTier:)`
   - `GrokLogUsageScanner.parse(_:since:pricing:)`
   - `CursorUsageMapper.appendSpendLines(rows:now:to:)`
3. Extend `SpendTileMapper.appendTokenUsage` to accept optional model aggregates and attach the correct period breakdown:
   - `Today`: today's model list
   - `Yesterday`: yesterday's model list
   - `Last 30 Days`: aggregate all days in the fetched/scanned window
4. Add a structured field to `.values` lines, for example `modelBreakdown: ModelUsageBreakdown?`.
5. Thread that field through:
   - `MetricLine` Codable encode/decode
   - `WidgetData`
   - `WidgetDataStore.resolve(_:)`
   - `ProviderSnapshotCache` storage key bump
6. Decide local API behavior in `LocalUsageAPI.WireLine`.
   - If model details are UI-only, omit them from the public wire shape deliberately and document that.
   - If exposed, add an explicit documented field to `docs/local-http-api.md` rather than relying on internal `MetricLine` Codable.

UI path:

1. Add a `ModelUsageDetail` SwiftUI view modeled after `UsageTrendDetail`.
2. Add a hover coordinator modeled after `TrendHoverState` or generalize `TrendHoverState` into a reusable delayed-hover-popover state.
3. In `WidgetRowView.unboundedRow`, when `data.isUsagePeriod && data.modelBreakdown != nil`, attach a `.popover` with the coordinator.
4. Keep existing `hoverTooltip` behavior for exact figures and unknown-model icons. Do not add extra `hoverTooltip` affordances inside the model panel unless explicitly requested.
5. Keep the panel small enough for the 320pt host width. A width around the trend detail's 240pt is plausible; if a chart is included, cap height and use internal scrolling rather than letting content force dashboard panel height.

## Risks and constraints

Swift 6 strict concurrency:

- Provider classes are `@MainActor`, while scanners are actors or `Sendable` structs. New aggregate types must be `Sendable`.
- `MetricLine` and `ProviderSnapshot` are `Sendable` and `Codable`; any new attached payload must be both.
- Avoid capturing non-Sendable store/view state inside scanner task groups.
- `PanelHeightModifier` deliberately uses a nonisolated `GeometryEffect` because `Animatable` has nonisolated requirements. Do not add model-hover height logic that synchronously mutates AppKit from SwiftUI layout.

Popover and hover behavior:

- A large in-window overlay can be clipped by the panel or scroll view. Use SwiftUI `.popover` or a separate non-activating `NSPanel` pattern.
- `hoverTooltip`'s panel is click-through and text-only; it is not appropriate for a structured Models panel with a chart or internal hover.
- Row-level hover must coexist with reorder drag gestures and context menus in `WidgetGroupedListView`.
- The dashboard SwiftUI tree survives panel close; any hover coordinator must be dismissed from the same close paths as tooltips/trend popovers.

Performance:

- Cursor CSV parse cost already exists on every Cursor refresh. Model grouping is cheap relative to network fetch and parse.
- Claude/Codex per-file parse caches keep repeated refreshes cheap; model grouping reruns over cached entries/events each refresh, like current day aggregation.
- Grok scans a single append-only file without a parse cache. A model panel increases only aggregation state, not file reads, but large logs could make Grok the highest-risk provider.

Data quality:

- Cursor CSV spend is described in UI as "From your Cursor usage history"; internally it is locally imputed from CSV token rows and `ModelPricing`, with `estimated: false` currently suppressing the local-estimate info icon. Be careful with copy: the dollars are not directly billed dollars from a `Cost` CSV column in current code.
- Claude may carry explicit `costUSD` on some log lines; those should win over local pricing, including in model aggregates.
- Codex model fallback (`gpt-5`) and `codex-auto-review` date mapping are approximations inherited from the scanner. The panel should not imply perfect billing truth.
- Grok model attribution depends on prior model events per process id. Missing model context should be visible as unattributed usage, not silently dropped.
- Display grouping is unresolved. Current `ModelPricing` resolves slugs to rates but does not expose a user-facing family display name. A first version can group by raw model/canonical slug; a polished version may need supplement metadata or a small display-name formatter.

## Final recommendation

Build the data feature as an extension of the shared spend spine, not as a separate provider-specific widget.

The best integration point is:

- compute per-model aggregates inside each provider's existing scan/CSV aggregation function, before `DailyUsageSeries` loses the model dimension
- pass those aggregates into `SpendTileMapper`
- attach the period-specific breakdown to the same `MetricLine.values` rows that back `Today`, `Yesterday`, and `Last 30 Days`
- render from `WidgetRowView` using a delayed SwiftUI hover popover patterned after `UsageSparkline` and `UsageTrendDetail`

Provider rollout order should be Cursor first, then Claude and Codex, then Grok once unattributed/unknown handling is defined. This gives immediate value with the least risk while keeping the architecture provider-neutral from the start.
