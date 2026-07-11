# PR #740 archaeology: per-model usage leaderboard

> **Historical / superseded.** This report records the repository as it stood on 2026-07-04. A
> provider-neutral model breakdown on spend-row hover shipped on 2026-07-04 and has evolved since;
> see [Dashboard rows](../../dashboard.md#rows),
> [`SpendTileMapper.swift`](../../../Sources/OpenUsage/Providers/SpendTileMapper.swift), and
> [`ModelUsageDetail.swift`](../../../Sources/OpenUsage/Views/ModelUsageDetail.swift) for current
> behavior and implementation. The historical branch analysis below is intentionally unchanged.

Research date: 2026-07-04. PR remains **open** and **unmerged** on branch `claude/eager-banach-ecf5a1` (~106 commits behind `main` as of this writing). This note compares that branch to current `main` for anyone revisiting per-model / model-hover UX.

## (a) What PR #740 did

**Goal:** An opt-in Cursor **Models** widget — a spend-sorted per-model leaderboard for the last 30 days, reusing the same usage CSV as Today / Yesterday / Last 30 Days.

**Data path**

- Fetched Cursor’s usage-events CSV in `CursorProvider` (same window as spend tiles).
- Parsed rows into `CursorUsageCSVRow` (date, model slug, token buckets, `imputedCostDollars`).
- **`CursorModelBreakdown`** (cursorcat `ModelBreakdownAggregator` port): group rows by **model family** via `CursorPricing.family(for:)` and bundled **`model_manifest.json`** (`family_id`, `family_display_name`); sum tokens and imputed dollars; cent-snap once per family; sort by spend → tokens → name; fold sub-**3%** spend tail into **Other** (never fold unpriced models); attach per-raw-model **variants** for hover detail.
- **`CursorUsageMapper.appendModelLeaderboard`** emitted `MetricLine.modelBreakdown(label: "Models", models: entries, note: …)`.

**Metric / UI plumbing**

- New types: `ModelUsageEntry`, `ModelVariantUsage`, `MetricLine.modelBreakdown`.
- `WidgetData`: `isModelList`, `modelEntries`, `modelNote` (parallel to chart fields).
- `WidgetDescriptor.modelBreakdown` → `cursor.models`, **off by default**, **secondary** (expand caret), **`pinnable: false`**.
- Views: **`ModelLeaderboardRow`** (top 3 family names + rank badges, no dollars inline) + hover popover **`ModelLeaderboardDetail`** (full list, spend, tokens, **proactive `hoverTooltip`** on variants — flagged in review).
- Threaded through `WidgetDataStore`, `WidgetRowView`, `LocalUsageAPI` (`type: "models"`), snapshot cache bump **v5 → v7**.
- Docs: `docs/dashboard.md`, `docs/providers/cursor.md`; small **AGENTS.md** note on `pinnable: false` for list/chart widgets.
- Tests: `CursorModelBreakdownTests`, extensions to `CursorSpendTests` / `LayoutStoreTests`.

**Stated follow-ups (in PR body)**

- Generalize to **Grok** (“model attribution already computed”).
- **Claude / Codex** via `ccusage --breakdown` on the existing ccusage spend path.

**Per-model inputs the PR actually depended on**

| Source | Fields used |
|--------|-------------|
| Cursor usage CSV | Per-row `Model`, token columns, date |
| Row pricing | `CursorPricing.estimatedCostDollars` / per-row `imputedCostDollars` (non-optional `Double` on the branch) |
| Family grouping | `model_manifest.json` → `family_id`, `family_display_name` per pricing entry |
| Window | Same ~30-day CSV fetch as spend tiles (not re-aggregated from day buckets) |

---

## (b) Why it did not land (discussion / review)

Nothing in GitHub formally closed the PR; it stalled after review. Recorded reasons and signals:

1. **Product / UX uncertainty (owner)** — [Comment on #740](https://github.com/robinebers/openusage/pull/740#issuecomment-4802994002): works for Cursor and could extend to other providers, but *“I wonder if there is a better way to display this. Maybe as a chart or something? Not sure.”* That reads as dissatisfaction with the **leaderboard row + hover popover** pattern, not the underlying aggregation.

2. **Cursor-only delivery vs multi-provider intent** — The implementation is entirely Cursor-scoped (`CursorModelBreakdown`, `cursor.models`, CSV-only). The PR itself notes cross-provider extension as **follow-up**, which left the feature feeling narrow relative to Claude/Codex/Grok spend tiles users already see.

3. **Review friction (“too many problems” in the small stuff)**  
   - **Codex review (P1):** Proactive **`hoverTooltip`** on model rows conflicts with `AGENTS.md` (“only add tooltips when explicitly asked”). Full detail already in the hover popover; variant tooltips were redundant and against convention.  
   - **Greptile (P1, fixed on branch):** Docs claimed **5%** “Other” threshold while code used **3%** (`tailThresholdFraction = 0.03`).  
   - **Greptile / Codex (P2):** Local HTTP API emitted `models` lines but **`docs/local-http-api.md`** was not updated; **`WireModel`** omitted `variants` (external consumers could not reconstruct variant breakdown).

4. **Automated reviewers were optimistic; humans did not merge** — Greptile/Cursor Bugbot scored the diff as low-risk and merge-ready, but there were no approving human reviews and no merge before `main` moved on sharply (see below).

---

## (c) What changed on `main` since (why the branch is severely outdated)

### PR #827 — native log scanners + dynamic pricing (merged 2026-07-02)

This is the largest break. #740 assumes a **Cursor-local pricing stack** that no longer exists:

| #740 branch | Current `main` |
|-------------|----------------|
| `CursorPricing`, `CursorModelManifest`, bundled **`model_manifest.json`** | **Removed.** All imputation through **`Sources/OpenUsage/Pricing/`** (`ModelPricing`, `ModelPricingStore`, LiteLLM + models.dev + **`pricing_supplement.json`**) — see **`docs/pricing.md`**. |
| `CursorUsageCSV.parse(csv:)` without injected pricing | **`CursorUsageCSV.parse(csv:pricing:)`**; `imputedCostDollars` is **`Double?`** (nil = unpriced). |
| `CursorPricing.family(for:)` / `family_display_name` for leaderboard labels | **No `family_id` in supplement.** Grouping is via **alias rules → canonical keys**, not display families. Human-readable names must be derived elsewhere (formatting slug / catalog metadata), not from manifest fields #740 added. |
| Claude/Codex spend via **`CcusageRunner`**; follow-up **`ccusage --breakdown`** | **`CcusageRunner` deleted.** **`ClaudeLogUsageScanner`** / **`CodexLogUsageScanner`** read local logs; output **`DailyUsageSeries`** only (day buckets). |
| Cursor spend described as manifest-priced CSV | Same CSV source, but rows priced with **`ModelPricing`**; unknown models tracked per day for spend-tile warnings (`unknownModelsByDay` in **`CursorUsageMapper.appendSpendLines`**). |

### Other `main` deltas relevant to a rebase

- **No `MetricLine.modelBreakdown`**, no `ModelUsageEntry`, no `isModelList` / `ModelLeaderboard*` views on `main`.
- **Snapshot cache key:** #740 bumps to **`openusage.providerSnapshots.v7`** (model breakdown + variants). `main` is at **`v6`** (`.values` **`unknownModels`** on spend tiles) — different schema story; a revival would need a fresh bump and migration reasoning.
- **~106 commits** on `main` not on the PR branch (Copilot, Claude Cowork logs, notifications, enterprise Cursor paths, pricing supplement churn, etc.) — expect heavy conflicts in Cursor provider, mappers, `MetricLine`, `WidgetDataStore`, and docs.
- **Grok:** `GrokLogUsageScanner` **does** attribute each inference to a model (per-`pid` tracking) but, like Claude/Codex scanners, **aggregates to daily totals only** — no existing `MetricLine` carries per-model series. #740’s “Grok already has model attribution” is still true at scan time, but nothing exposes it in the UI pipeline today.
- **Claude / Codex:** Scanners retain **per-event `model`** (`ClaudeLogUsageScanner.Entry.model`, `CodexLogUsageScanner.Event.model`) but **discard the dimension** when building `DailyUsageSeries` — same structural gap #740 called out for Cursor day-bucketing, now the common pattern for all log-based providers.

### Pricing supplement (operational change)

- **`Sources/OpenUsage/Resources/pricing_supplement.json`** is published to GitHub Pages; apps refresh ~daily without a release. #740’s approach of extending **`model_manifest.json`** for family metadata is obsolete; new models/aliases belong in the **supplement** and **`docs/pricing.md`** maintainer flow.

---

## (d) Reusable vs dead

### Largely dead (do not cherry-pick blindly)

- **`CursorModelBreakdown.swift`** as written — imports **`CursorPricing.family`**, **`toCents`**, and non-optional **`imputedCostDollars`**; must be rewritten against **`ModelPricing`** and optional costs.
- **`CursorModelManifest` / `family_id` decoding** — manifest file and type removed on `main`.
- **`MetricLine.modelBreakdown` + entire widget pipeline** — no counterpart on `main`; product direction may prefer **chart / hover-on-spend-row** over a second opt-in widget (per owner comment).
- **Cache v7 bump, LocalUsageAPI `models` wire type, layout defaults for `cursor.models`** — none shipped; docs on `main` never described the Models widget.
- **Tests fixing `CursorTokenUsage` / old CSV shape** — token struct is shared **`TokenBreakdown`**; pricing injection required in **`makeRow`** helpers.
- **ccusage breakdown follow-up** — path deleted.

### Salvageable concepts (reimplement on current architecture)

- **Aggregation semantics:** family collapse (needs a **new grouping policy** — e.g. canonical key from alias rules, or explicit family map in supplement), spend sort, cent snapping once per bucket, skip zero-usage rows, **3% Other** tail rules, never fold unpriced, variant sub-rows for `-fast` / thinking slugs.
- **Data still available without new APIs:**  
  - **Cursor:** raw **`[CursorUsageCSVRow]`** after parse (model dimension still on each row).  
  - **Claude / Codex / Grok:** re-run or extend scanners to emit **per-model totals** before day aggregation (events already carry model).  
- **UI patterns (optional):** measured-height scroll cap from **`ModelLeaderboardDetail`**; **`TrendHoverState`** dwell/grace for hover surfaces; rank-inline / detail-on-hover split — but **avoid proactive tooltips** unless product explicitly wants them; consider aligning with owner’s “chart?” instinct or **model detail on existing spend/trend hovers** instead of a dedicated widget.
- **Cross-provider framing:** **`SpendTileMapper`** and **`DailyUsageSeries`** are the shared spend spine; any per-model feature should likely feed **all four** imputed providers (Claude, Codex, Cursor, Grok) for parity, using one pricing engine and consistent unknown-model handling.

### Suggested revival checklist (if pursued)

1. Decide UX: separate widget vs hover on existing rows vs chart (resolve #740 open question).
2. Define **display grouping** without `family_display_name` (supplement metadata vs slug formatting vs catalog).
3. Implement **`ModelBreakdownAggregator`** (provider-agnostic) over row/event streams, not over day-only series.
4. Extend **`MetricLine` / API** only if the chosen UX needs it; update **`docs/local-http-api.md`** if exposed.
5. Bump **`ProviderSnapshotCache`** with a documented schema change.
6. Confirm metric placement defaults with owner per **AGENTS.md** (four decisions).

---

## References

- PR: https://github.com/robinebers/openusage/pull/740  
- Pricing overhaul: https://github.com/robinebers/openusage/pull/827 (merged)  
- Current pricing doc: `docs/pricing.md`  
- Shared spend tiles: `Sources/OpenUsage/Providers/SpendTileMapper.swift`  
- Cursor CSV + day aggregation (model still dropped): `Sources/OpenUsage/Providers/Cursor/CursorUsageMapper.swift` (`appendSpendLines`)
