# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity reports two shared quota pools, each with a rolling 5-hour and a weekly window. Eligible accounts can also have a separate Gemini 4 Argon weekly quota:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool, rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Argon Weekly | The separate Gemini 4 Argon weekly quota, when reported |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, …), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |
| Usage Trend | Daily token usage from local Antigravity conversations |
| Today / Yesterday / Last 30 Days | Local token usage and estimated API-equivalent spend |

When Antigravity reports your subscription tier (such as `Pro` or `Ultra`), OpenUsage shows it beside the provider name.

The shared Gemini pool is named Session and Weekly to match the other providers' rows. Paid Pro plans have a separate Argon weekly quota; Ultra includes Argon in its larger shared Gemini quota, shown by Session and Weekly. The shared non-Gemini pool (Claude and GPT models) is shown under the Claude name, like Codex's Spark pair. The quota API reports fractions, while token usage and estimated spend come separately from local conversation databases.

Argon Weekly reads **No data** when the response does not provide a usable separate weekly quota, including older endpoints and accounts without access. OpenUsage uses the returned quota information rather than guessing availability from the plan name.

While a pool's rolling 5-hour window has no usage yet, that meter reads **Not started** on the trailing label instead of a reset countdown; hover explains that the session begins after your first message. The weekly meters always show a normal reset countdown.

## Where credentials come from

OpenUsage never asks for a token — it reads what Antigravity already has:

- **Antigravity running** — OpenUsage talks to the app's local language server (the richest source, and where the plan name comes from).
- **App closed** — it falls back to the OAuth token Antigravity / `agy` store in your macOS Keychain and queries Google's Cloud Code API. An expired token is refreshed automatically (OpenUsage never writes back to Antigravity's own keychain item). Its short-lived cache is reused only while the same Keychain login is present and readable.

If neither is available you'll see *Start Antigravity or run `agy` and try again.*

## Spend and usage history

OpenUsage reads generation token counts, including the fixed system prompt, from every `~/.gemini/antigravity*/conversations` store (the `agy` CLI, the Antigravity IDE, the Antigravity 2.0 app, and ACP sessions) and estimates their API-equivalent cost using the shared [model pricing](../pricing.md). Today, Yesterday, and Last 30 Days contribute to the Total Spend card alongside the other providers. These are estimates, not charges from your Antigravity subscription, and conversation data never leaves your Mac. Previously scanned conversations are reused on refresh, so only new generation records need to be read.

When the model picker is on its default, Antigravity logs a placeholder ID (`gemini-default`, `gemini-pro-default`) and records the model that actually served the turn as a display label such as "Gemini 3.1 Pro (High)". OpenUsage prices those turns by that label, falling back to the placeholder ID when the label has no known rate (`gemini-pro-default` prices as Gemini 3.1 Pro). Anything that still cannot be priced remains visible in the unknown-models warning.

The model breakdown groups by model family: effort variants such as `gemini-3.1-pro-low`, display labels, and placeholder IDs all count under one `gemini-3.1-pro` row, since they bill at the same rate. Names OpenUsage cannot map keep their raw text. Prompt-context records that carry no model and no generated tokens are not generations and are ignored.

Subagents that Antigravity launches with a model tier (`flash_lite`, `flash`, `pro`) are logged with a `-tiered` model ID, such as `gemini-3.7-flash-tiered`. That is the same model at the same rate, so it counts under the base model's row.

Gemini 4 Argon trial, preview, and effort variants use the bundled [Argon API rates](../pricing.md) and share one `gemini-4-argon` breakdown row. Pricing updates also restore token counts and estimated spend for previously scanned local Argon conversations on refresh.

The transcript logs don't include token accounting, so they aren't used. Missing or unpriced models aren't assigned an invented price, and unusually large generation records are skipped with a warning to keep memory usage bounded.

## Troubleshooting

- **"Start Antigravity or run `agy`…"** — sign in to the Antigravity app (or run `agy`) so a usable token exists, then refresh.
- **"Couldn't read Antigravity credentials…"** — unlock Keychain or sign in to Antigravity again. OpenUsage will not use its cached access token until the current login can be verified.
- **The weekly meters show "No data"** — your Antigravity build doesn't expose the quota-summary endpoint yet (only newer builds do). The 5-hour meters still work from the older endpoints; updating Antigravity brings the weekly meters back.
- **Argon Weekly shows "No data"** — the response did not include an enabled, usable separate Argon weekly quota. On Ultra, Argon uses the shared Gemini quota shown by Session and Weekly. Older endpoints may also omit the separate quota. A model appearing in Antigravity's picker does not mean its quota is available.
- **A meter shows "No data"** — that pool/window wasn't in the latest response (some tiers only report certain windows). The other meters still update.
- **Spend or usage history shows "No data"** — Antigravity hasn't written usable conversation databases yet. Run an Antigravity or `agy` session, then refresh.
- **Where did the Gemini Pro and Flash meters go?** — merged: both models draw from the one shared Gemini pool, which is now the single Session meter.
- **Quotas look full after heavy use** — the 5-hour windows reset on a rolling basis and the weekly windows once a week; the reset time is shown on each meter.

## Under the hood

Best source first: the local language server discovered by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. OpenUsage binds its short-lived refreshed-token cache to a one-way fingerprint of the current Keychain refresh credential. Logout, account changes, legacy caches, and expired or malformed entries cannot reuse a previous account's access token. On each source OpenUsage asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code).

For the quota summary, Cloud Code asks production (`cloudcode-pa`) first. When production's answer has all four shared-pool windows, that answer is used and the daily host (`daily-cloudcode-pa`) isn't asked. Otherwise, including when production fails or rejects the sign-in, OpenUsage also asks the daily host and combines the two answers, because one host can leave out a whole pool (for example, return only the Claude meters). Production's answer wins where both report the same window. A window neither host reports shows **No data** for that refresh. Other Cloud Code requests try production first, then the daily endpoint after a network error or an error response other than a sign-in rejection.

The four shared-pool windows use their known bucket IDs. Argon Weekly requires the exact `Gemini 4 Argon` group and one explicitly weekly bucket with a separate ID and usable remaining fraction. Disabled, malformed, or ambiguous Argon quotas are omitted.

Builds without the summary endpoint fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely). Their shared-pool quotas are merged by keeping each pool's worst remaining fraction. Argon entries are excluded because those responses do not identify their quota's pool or period; they cannot supply Argon Weekly. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field. With the app closed, the plan comes from Cloud Code's `loadCodeAssist`, called the way the Antigravity app calls it — its client metadata and User-Agent — because Google leaves out your tier for any other caller; a known `paidTier.id` (Pro, Ultra, Ultra Lite) wins over the tier's display name. Spend history comes from the generation-accounting protobuf records in each local conversation database.

Thanks to [FelixIsaac](https://github.com/FelixIsaac) for identifying the conversation-database source and contributing the original SQLite/protobuf implementation in [issue #1120](https://github.com/robinebers/openusage/issues/1120) and [pull request #1058](https://github.com/robinebers/openusage/pull/1058).

> Reverse-engineered from the app and language-server binary; endpoints and storage may change without notice.
