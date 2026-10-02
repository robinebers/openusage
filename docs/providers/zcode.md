# Zcode Usage in Z.ai

Tracks the traffic the **Zcode** CLI sends from this Mac — the requests it makes through its built-in
Z.ai coding plan. Everything is read from Zcode's own local accounting database, so there is no login,
no key, and no network call.

Local accounting shows how much this machine ran through Zcode. It supplies the Usage Trend,
Today, Yesterday, and Last 30 Days rows in the [Z.ai card](zai.md), together with token counts and
estimated spend. The same totals contribute to Cost, Cost/MTok, and Tokens summaries.

## Where the data comes from

Use Zcode normally. It logs one row per model request to `~/.zcode/cli/db/db.sqlite` (the `model_usage`
table) with the full per-request token breakdown. OpenUsage opens that database **read-only** and
aggregates it by day. `ZCODE_HOME` is honored if you relocate Zcode's home; every `*.sqlite` file under
`<home>/cli/db` is read, so a future sharded store works without an update.

Z.ai is detected from an API key or local Zcode usage: first-run detection looks for at least one request that recorded
tokens in that database. The database is read locally. If iCloud sync is enabled, normalized daily usage can be shared with
your other Macs; raw database rows and credentials are never uploaded.

## Why the dollars are estimated

Token counts are **measured** — they come straight from Zcode's own accounting. The dollars are
**estimated** (that's the ⓘ): OpenUsage prices those tokens at Z.ai's public per-million rates through
the shared [model pricing](../pricing.md). Subscription and off-peak plans don't bill at those rates, so
treat the dollars as what the same traffic would have cost pay-as-you-go — useful for comparing days and
models, not a copy of an invoice.

Zcode normalizes its input count so that **`input_tokens` already includes
cache reads and cache writes**. Pricing the whole figure at the input rate would count cached tokens
twice, so OpenUsage bills the non-cached remainder as input and the cached portion at the cache-read
rate and cache writes at the cache-write rate. The token total still matches the one Zcode records.

## Troubleshooting

- **No local spend** — there is no Zcode usage in the current window. Run a Zcode
  session (or set `ZCODE_HOME` if you relocated its home), then refresh.
- **"Couldn't read Zcode's local database"** — the database exists but couldn't be read this refresh.
  Quit Zcode and refresh; if it persists, check the permissions on `~/.zcode`.
- **Cost summary has no Z.ai entry** — nothing was logged in that period. Days more than 30 days old fall
  outside the window.
- **Local totals are incomplete** — models with no known pricing are excluded from local token and spend totals until pricing is available.

## Under the hood

Read-only `sqlite3` against every `*.sqlite` under `~/.zcode/cli/db`, selecting `model_usage` rows whose
`started_at` is inside the tile window and whose combined token buckets are non-zero (an errored or
cancelled request logs zeros). Each row contributes `started_at`, `model_id`, and the input / output /
cache-read / cache-creation buckets to the shared daily accumulator. Unknown models raise the spend row’s warning triangle and are excluded from token and spend totals until pricing is available.
