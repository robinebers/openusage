---
name: pricing-update
description: Sync OpenUsage's pricing supplement with Cursor's published model pricing. Pulls https://cursor.com/docs/models-and-pricing.md, diffs it against pricing_supplement.json, updates entries/aliases/multipliers, validates, and opens a PR. Use when Cursor adds or re-prices models, a spend tile shows a warning triangle for an unpriced model, or a periodic pricing check is due.
---

# Pricing Update

`Sources/OpenUsage/Resources/pricing_supplement.json` prices the models no public catalog carries (Cursor-native models like `auto`, `composer-*`, `github_bugbot`), supplies fast-variant multipliers, and maps provider log/CSV slugs to canonical pricing keys. On merge to `main`, `.github/workflows/pricing-supplement.yml` validates it and publishes it to GitHub Pages; installed apps pick it up within ~a day — no release needed. Full background: `docs/pricing.md`.

Only the supplement needs manual care. Normal API models (new Claude/GPT/Gemini/Grok releases) are priced automatically by the daily LiteLLM and models.dev fetches — do not add them to the supplement unless they need an alias rule or the catalogs are wrong.

## Steps

### 1. Pull the source of truth into context

Fetch https://cursor.com/docs/models-and-pricing.md and read the whole thing. This is the canonical source for:

- Cursor-native model prices (`auto`, `composer-*`, Bugbot) — input, cache write, cache read, output, all USD per million tokens.
- Which models have a fast variant and what the fast pricing is.
- Long-context tiers (e.g. Sonnet 1M) that bill the whole request at the >200k rate.
- Model names/slugs as Cursor spells them (needed for alias rules).

### 2. Diff against the current supplement

Read `Sources/OpenUsage/Resources/pricing_supplement.json` and compare:

- **Price changes** on existing `pricing` entries.
- **New Cursor-native models** missing from `pricing`.
- **Removed/renamed models** — never delete an entry that old usage data may still reference; keep it so historical days keep their dollars. Only remove an entry if it was outright wrong.
- **`fast_multipliers`** — for API models whose fast variant is priced as a multiplier of the base rate. Only needed when the catalogs don't carry a `-fast` key themselves.
- **`alias_rules`** — a new model usually needs one, because Cursor CSV slugs and Codex/Claude log names rarely match catalog keys exactly (thinking suffixes, effort levels like `-low`/`-high`/`-xhigh`, dot vs dash versions). Follow the existing patterns: anchored regex, escaped dots, optional effort/thinking groups. `-fast` variants need their own rule ordered BEFORE the base rule (first match wins).

Where a model exists in LiteLLM or models.dev, prefer an alias to that canonical key over duplicating prices in the supplement.

### 3. Edit the supplement

- Update `updated_at` to today (YYYY-MM-DD).
- Keep the file's style: 2-space indent, rates as plain numbers, `$comment` explanations for non-obvious entries.
- Rates are USD per million tokens; cache read defaults matter — copy the exact numbers from the Cursor page, don't infer.

### 4. Validate

Run the same checks CI runs, plus the pricing tests:

```sh
python3 - << 'PY'
import json, re, sys
with open("Sources/OpenUsage/Resources/pricing_supplement.json") as f:
    s = json.load(f)
problems = []
for m, e in s["pricing"].items():
    for f_ in ("input_per_million", "output_per_million"):
        if not isinstance(e.get(f_), (int, float)):
            problems.append(f"pricing[{m}].{f_} missing or not a number")
for r in s["alias_rules"]:
    try: re.compile(r["pattern"])
    except re.error as err: problems.append(f"{r['pattern']!r}: {err}")
    if not r.get("canonical"): problems.append(f"{r['pattern']!r} has no canonical")
for m, x in (s.get("fast_multipliers") or {}).items():
    if not isinstance(x, (int, float)) or x <= 0:
        problems.append(f"fast_multipliers[{m}] must be positive")
sys.exit("FAILED:\n" + "\n".join(problems)) if problems else print("Supplement OK")
PY

swift test --filter "ModelPricing|PricingBundledResource"
```

If a new alias rule maps a slug that appears in real usage, add a resolution test case in `Tests/OpenUsageTests/ModelPricingTests.swift`.

### 5. Open a PR

Branch from `main`, commit (`fix(pricing): ...` or `feat(pricing): ...`), and open a PR following the repo's PR description structure (TL;DR / What was happening / What this changes). Cite the Cursor doc as the source and list each price or alias change explicitly so the owner can verify numbers at a glance. Never push pricing changes directly to `main`.

### 6. Verify publication after merge

Once merged, the `Publish pricing supplement` workflow runs. Confirm it landed:

```sh
gh run list --workflow=pricing-supplement.yml --limit 1
curl -s https://robinebers.github.io/openusage/pricing_supplement.json | python3 -c "import json,sys; print(json.load(sys.stdin)['updated_at'])"
```

The `updated_at` served must match the merged file. Publishing is two hops: the supplement workflow pushes the file to the `gh-pages` branch, then the `Deploy Pages` workflow (defined on the `gh-pages` branch itself; the repo's Pages source is "GitHub Actions") deploys that branch to the live site. If the URL is stale after ~10 minutes, check `gh run list --workflow=deploy-pages.yml` and re-run it with `gh workflow run deploy-pages.yml --ref gh-pages`.

## Optional: refresh bundled snapshots

The bundled LiteLLM/models.dev snapshots (`pricing_*_snapshot.json`) are a separate concern — offline fallbacks refreshed with `./script/update_pricing_snapshots.sh`, typically before a release. Staleness is harmless; only regenerate them if asked or as part of release prep, in their own commit.

## Rules

- USD per million tokens everywhere; exact numbers from the Cursor page, never inferred.
- Prefer aliasing to LiteLLM/models.dev keys over duplicating prices in the supplement.
- Never delete pricing entries that historical usage may reference.
- `-fast` alias rules come before their base-model rules.
- Always bump `updated_at`; always go through a PR.
