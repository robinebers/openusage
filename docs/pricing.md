# Model Pricing

How OpenUsage turns token counts into the estimated dollars on the Claude, Codex, Cursor, and Grok spend tiles. Grok uses the cost recorded in its session logs when available and only estimates older turns without one. OpenRouter and OpenCode do not use these estimates because their sources already report the cost directly.

## Where prices come from

Prices are layered from three sources; when the same model appears in more than one, the higher layer wins:

1. **OpenUsage pricing supplement** — a small JSON file maintained in this repo and published to GitHub Pages. It covers models no public catalog carries (Cursor-native models like `auto` and `composer-*`), fast-variant multipliers, and alias rules that map provider log/CSV slugs to catalog keys.
2. **LiteLLM** — the community-maintained `model_prices_and_context_window.json`, covering the vast majority of API-priced models.
3. **models.dev** — a gap-filler for models LiteLLM misses (e.g. some brand-new or niche models).

The app ships with bundled snapshots of all three, so pricing works offline and on first launch. At runtime each source is refetched about once an hour (with ETag revalidation) and cached in `~/Library/Application Support/OpenUsage/pricing/`. A refresh never blocks a usage scan — scans always price against the freshest data already on hand.

Because the supplement is published to GitHub Pages on merge, a pricing correction reaches installed apps within about an hour — no app update needed.

Updating the app also works. The supplement carries an ISO-8601 `updated_at` timestamp, and the app uses whichever of the cached and bundled copies is newer, so a build shipping fresher rates applies them straight away instead of waiting on the cache to expire. Timestamp precision matters because multiple pricing changes can land on the same day. Older date-only values remain supported. This matters most offline: without it, an old cache would shadow the shipped rates for as long as the feed stayed unreachable.

## How a model name resolves

Log and CSV model names rarely match a catalog key exactly, so resolution tries, in order: supplement alias rules, exact key match, fast-variant handling (a `-fast` suffix resolves the base model and applies its fast multiplier), then fuzzy matching — provider prefixes (`anthropic/`, `xai/`, …), dated suffixes (`claude-sonnet-4` ↔ `claude-sonnet-4-20250514`), and separator differences (`grok-4-3` ↔ `grok-4.3`). Fast variants without an explicit price or model-specific multiplier stay unpriced instead of silently using the standard-speed rate.

Requests routed by [Cursor Router](https://cursor.com/docs/cursor-router.md) are a special case: instead of a slug, Cursor's export names the model it picked in plain words, like `Opus 5 (Auto Balanced)`. Alias rules map those labels to the same rates as the model itself, so a routed request costs what it would have cost picked by hand. The label stays as written in the model breakdown, so you can still tell which requests the router handled.

Gemini 3.8 Flash includes Cursor effort variants such as `gemini-3.8-flash-high`, preview variants, and `Gemini 3.8 Flash (Auto…)` labels. These use the bundled API rates even before the first pricing refresh: $0.75 input, $0.75 cache writes, $0.075 cache reads, and $3.75 output per million tokens. As with Gemini 3.7, the output rate follows [Google's API pricing](https://ai.google.dev/gemini-api/docs/pricing), despite Cursor's table listing $3.50. Google lists these introductory rates through December 31, 2026.

A model no source can price is left out of the spend figures unless its session already records the actual cost. Otherwise, its tokens don't count toward the day's tile, the Usage Trend, or the model breakdown, because a token count next to a dollar figure that ignores part of it would be misleading. A warning triangle on the affected tiles lists the unpriced models, and a day where nothing could be priced reads "No data".

Codex offers an optional **Fallback Model** under **Customize → Codex → Cost Estimates**. It defaults to **None**, which keeps the behavior above. Choosing a model estimates otherwise-unpriced local usage at that model's rates, including cached input, long-context requests, and the session's speed tier. Known prices still win. The unknown-model warning triangle and its tooltip stay visible: a fallback estimates the cost but does not establish the model's own price. Changing the choice recalculates the local history, including earlier days; it does not change the model used by Codex. Choosing **None** excludes unpriced usage again. The model breakdown and trend source note identify fallback estimates only for the days shown. Estimates outside the history window do not affect these notes. Synced history keeps the estimates made on each source Mac; this preference does not reprice another Mac's history.

The picker lists public text/code models from the supplement's `fallback_models.codex` list, and only offers entries with usable exact pricing. It never reads account-specific model lists. The bundled list works offline; list updates arrive through the existing supplement refresh. Opening these settings recalculates a saved choice, and a change in its availability after a list refresh recalculates the local totals again. If a saved choice becomes unavailable, the settings show a warning and remove its fallback estimates; if its pricing returns, the estimates return. Unknown-model warnings remain in both cases.

## What the estimate includes

Costs are computed per usage event from four token buckets — plain input, cache writes, cache reads, and output — at the model's per-million-token rates, including 1-hour cache-write pricing, long-context tiers, and fast-variant multipliers. Most catalog tiers start above 200k prompt tokens; supported GPT-5.4, GPT-5.5, GPT-5.6, and GPT-6 Codex models switch above 272k input tokens. In either case, the higher rate applies to the whole request. A published cache discount is used when available; Codex cached input falls back to the full input rate when the source publishes no discount. Cursor's export combines many requests into each row, so OpenUsage uses the normal rate there rather than guessing that one request crossed the limit. When a Claude or Grok session records its own cost, that amount is used as-is. Nested Claude advisor usage has no carried cost, so it is priced separately from its tokens using the advisor model. Estimates represent API-rate value rather than a subscription bill.

## Privacy

The pricing refresh fetches three public price lists (from `raw.githubusercontent.com`, `models.dev`, and this repo's GitHub Pages). These requests carry no usage or log data — nothing about your usage leaves your Mac.

## Maintainer notes

- **Supplement changes** (new Cursor-native model, price correction, new alias): edit `Sources/OpenUsage/Resources/pricing_supplement.json`, sync entries from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md), and update `updated_at` to the current UTC timestamp. On merge to `main`, `.github/workflows/pricing-supplement.yml` publishes it to gh-pages; installed apps pick it up within about an hour. The bundled copy ships with the next release for first launches. The **pricing-update skill** (`.agents/skills/pricing-update/`) walks an agent through the whole sync: pull the Cursor page, diff, edit, validate, and open a PR.
- **Bundled snapshots** (`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): regenerate occasionally (e.g. before a release) with `script/update_pricing_snapshots.sh`. Staleness is harmless — runtime fetches override them.
