#!/bin/bash
# Regenerates the bundled pricing snapshots from the live feeds:
#
#   Sources/OpenUsage/Resources/pricing_litellm_snapshot.json      (LiteLLM model_prices)
#   Sources/OpenUsage/Resources/pricing_models_dev_snapshot.json   (models.dev api.json)
#
# The snapshots are the offline fallback for first launch / no network; at runtime the app fetches
# the same feeds daily and its disk cache overrides these. Staleness is therefore harmless, but
# refreshing them at release time keeps first launches accurate. Run from the repo root:
#
#   ./script/update_pricing_snapshots.sh
#
# The compact format must stay in sync with PricingCatalogCodecs.swift (compact codec + the
# defaulting rules of the LiteLLM/models.dev parsers): per-million rates, cache write defaults to
# the input rate, and cache read to a tenth of it. When cache read is synthesized, `cre:false`
# preserves that provenance so providers can distinguish the fallback from a published discount.
# After regenerating, `swift test` exercises the snapshots via the pricing resolution tests.
set -euo pipefail

cd "$(dirname "$0")/.."
RESOURCES="Sources/OpenUsage/Resources"

LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MODELS_DEV_URL="https://models.dev/api.json"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching LiteLLM pricing..."
curl -fsSL --max-time 120 "$LITELLM_URL" -o "$tmpdir/litellm.json"
echo "Fetching models.dev pricing..."
curl -fsSL --max-time 120 "$MODELS_DEV_URL" -o "$tmpdir/models_dev.json"

python3 - "$tmpdir" "$RESOURCES" << 'PY'
import json
import sys
from datetime import datetime, timezone

tmpdir, resources = sys.argv[1], sys.argv[2]
retrieved_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def compact_model(input_pm, output_pm, cache_write_pm, cache_read_pm, cache_read_explicit,
                  ia=None, oa=None, cwa=None, cra=None, fast=None):
    model = {"i": input_pm, "o": output_pm, "cw": cache_write_pm, "cr": cache_read_pm}
    if not cache_read_explicit:
        model["cre"] = False
    for key, value in (("ia", ia), ("oa", oa), ("cwa", cwa), ("cra", cra), ("fast", fast)):
        if value is not None:
            model[key] = value
    return model

def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

# LiteLLM: costs are per token; entries without both input and output cost are stubs -> skipped.
with open(f"{tmpdir}/litellm.json") as f:
    litellm = json.load(f)
models = {}
for key, entry in litellm.items():
    if not isinstance(entry, dict):
        continue
    i, o = number(entry.get("input_cost_per_token")), number(entry.get("output_cost_per_token"))
    if i is None or o is None:
        continue
    cw = number(entry.get("cache_creation_input_token_cost"))
    cr = number(entry.get("cache_read_input_token_cost"))
    provider_specific = entry.get("provider_specific_entry") or {}
    models[key] = compact_model(
        i * 1e6, o * 1e6,
        (cw if cw is not None else i) * 1e6,
        (cr if cr is not None else i * 0.1) * 1e6,
        cr is not None,
        ia=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("input_cost_per_token_above_200k_tokens"))),
        oa=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("output_cost_per_token_above_200k_tokens"))),
        cwa=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("cache_creation_input_token_cost_above_200k_tokens"))),
        cra=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("cache_read_input_token_cost_above_200k_tokens"))),
        fast=number(provider_specific.get("fast")) if isinstance(provider_specific, dict) else None,
    )
if not models:
    sys.exit("LiteLLM feed produced no usable entries - aborting.")
with open(f"{resources}/pricing_litellm_snapshot.json", "w") as f:
    json.dump({"retrieved_at": retrieved_at, "models": models}, f, sort_keys=True, separators=(",", ":"))
print(f"pricing_litellm_snapshot.json: {len(models)} models")

# models.dev: costs are already per million; ids stored bare, first provider (sorted) wins.
with open(f"{tmpdir}/models_dev.json") as f:
    models_dev = json.load(f)
models = {}
for provider_name in sorted(models_dev):
    provider = models_dev[provider_name]
    if not isinstance(provider, dict):
        continue
    for model_id, model in (provider.get("models") or {}).items():
        if model_id in models or not isinstance(model, dict):
            continue
        cost = model.get("cost") or {}
        i, o = number(cost.get("input")), number(cost.get("output"))
        if i is None or o is None:
            continue
        cw, cr = number(cost.get("cache_write")), number(cost.get("cache_read"))
        models[model_id] = compact_model(
            i, o,
            cw if cw is not None else i,
            cr if cr is not None else i * 0.1,
            cr is not None,
        )
if not models:
    sys.exit("models.dev feed produced no usable entries - aborting.")
with open(f"{resources}/pricing_models_dev_snapshot.json", "w") as f:
    json.dump({"retrieved_at": retrieved_at, "models": models}, f, sort_keys=True, separators=(",", ":"))
print(f"pricing_models_dev_snapshot.json: {len(models)} models")
PY

ls -lh "$RESOURCES"/pricing_*_snapshot.json
