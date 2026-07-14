# Model Pricing

How OpenUsage turns token counts into the estimated dollars on the spend tiles (Claude, Codex, Cursor, Grok). OpenRouter and OpenCode are the exceptions: OpenRouter's API reports billed dollars directly, and OpenCode records its own per-message cost in its local logs, so nothing here applies to them.

## Where prices come from

Prices are layered from three sources; when the same model appears in more than one, the higher layer wins:

1. **OpenUsage pricing supplement** — a small JSON file maintained in this repo and published to GitHub Pages. It covers models no public catalog carries (Cursor-native models like `auto` and `composer-*`), fast-variant multipliers, and alias rules that map provider log/CSV slugs to catalog keys.
2. **LiteLLM** — the community-maintained `model_prices_and_context_window.json`, covering the vast majority of API-priced models.
3. **models.dev** — a gap-filler for models LiteLLM misses (e.g. some brand-new or niche models).

The app ships with bundled snapshots of all three, so pricing works offline and on first launch. At runtime each source is refetched about once an hour (with ETag revalidation) and cached in `~/Library/Application Support/OpenUsage/pricing/`. A refresh never blocks a usage scan — scans always price against the freshest data already on hand.

Because the supplement is published to GitHub Pages on merge, a pricing correction reaches installed apps within about an hour — no app update needed.

## How a model name resolves

Log and CSV model names rarely match a catalog key exactly, so resolution tries, in order: supplement alias rules, exact key match, fast-variant handling (a `-fast` suffix resolves the base model and applies its fast multiplier), then fuzzy matching — provider prefixes (`anthropic/`, `xai/`, …), dated suffixes (`claude-sonnet-4` ↔ `claude-sonnet-4-20250514`), and separator differences (`grok-4-3` ↔ `grok-4.3`). Fast variants without an explicit price or model-specific multiplier stay unpriced instead of silently using the standard-speed rate.

A model no source can price is left out of the spend figures entirely — its tokens don't count toward the day's tile, the Usage Trend, or the model breakdown, because a token count next to a dollar figure that ignores part of it would be misleading. Instead, a warning triangle on the affected tiles lists the unpriced models, so you know the figures are incomplete and which model is responsible. A day where *nothing* could be priced reads "No data".

## What the estimate includes

Costs are computed per usage event from four token buckets — plain input, cache writes, cache reads, and output — at the model's per-million-token rates, including 1-hour cache-write pricing, long-context tiers, and fast-variant multipliers. Most catalog tiers start above 200k prompt tokens; supported GPT-5.4, GPT-5.5, and GPT-5.6 Codex models switch above 272k input tokens. In either case, the higher rate applies to the whole request. A published cache discount is used when available; Codex cached input falls back to the full input rate when the source publishes no discount. Cursor's export combines many requests into each row, so OpenUsage uses the normal rate there rather than guessing that one request crossed the limit. When a Claude log line carries an explicit `costUSD`, that value is used as-is. Nested Claude advisor usage has no carried cost, so it is priced separately from its tokens using the advisor model. The result is an estimate of API-rate value, not a bill: subscription plans don't charge per token.

## Privacy

The pricing refresh fetches three public price lists (from `raw.githubusercontent.com`, `models.dev`, and this repo's GitHub Pages). These requests carry no usage or log data — nothing about your usage leaves your Mac.

## Maintainer notes

- **Supplement changes** (new Cursor-native model, price correction, new alias): edit `Sources/OpenUsage/Resources/pricing_supplement.json`, sync entries from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md), and update `updated_at`. On merge to `main`, `.github/workflows/pricing-supplement.yml` publishes it to gh-pages; installed apps pick it up within about an hour. The bundled copy ships with the next release for first launches. The **pricing-update skill** (`.agents/skills/pricing-update/`) walks an agent through the whole sync: pull the Cursor page, diff, edit, validate, and open a PR.
- **Bundled snapshots** (`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): regenerate occasionally (e.g. before a release) with `script/update_pricing_snapshots.sh`. Staleness is harmless — runtime fetches override them.
