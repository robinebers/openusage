# Muse Code provider — Swift app (`robinebers/openusage`) — maintainer notes

This doc is the handoff for `feat/muse-code-provider` on fork `tomck/openusage`.
It covers the local-only spend provider plus the live quota meters added after the
`muse` CLI's `Everyday Usage` window was exhausted. The only UX surprise is a
**single keychain prompt** — see §4.

## 1. What the provider does

* **Local spend, no API:** `Sources/OpenUsage/Providers/Muse/MuseUsageScanner.swift:63` scans
  `<data>/muse/sessions/YYYY/MM/DD/<id>/session.jsonl` ( `~/.local/share/muse/sessions`
  or `$XDG_DATA_HOME/muse/sessions` via `MusePaths.swift:38` ) for `model_completed`
  run events (`payload_type==runtime.session`, `event.kind==model_completed`,
  `recorded_at` micros, `usage:{input_tokens, output_tokens, cached_tokens/cache_read_tokens,
  cache_write_tokens, reasoning_tokens}`, `model`). Reasoning folds into output
  (Meta bills it as output). Dedup by `(timestamp,model,tokens)` keeps mirrored/
  copied logs from double-counting; `subagent/` transcripts are skipped
  (`MuseUsageScanner.swift:63` `files.removeAll { contains("/subagent/") }`).

  Dollars are estimated through `Pricing` (`ModelPricingStore.shared.current()`,
  `PricingSupplement` entry `muse-spark-1.3` `$1.25/M in, $4.25/M out, $0.15/M cached`
  and `muse-spark-1.3-contributor` `$0.10/$0.20`). Unknown models are excluded
  from cost and surfaced as `unknownModelsByDay`.

  `MuseProvider.swift:46` `widgetDescriptors` = `Session`/`Weekly` percent meters
  + `UsageTrend` (machine-local, `estimatedCost:true`, `sourceNote`) + spend tiles
  (`SpendTileMapper`). `MuseUsageScanner` is an `actor` with
  `IncrementalJSONLScanner<Entry>` (`namespace:"muse", schemaVersion:1`) — only
  changed files re-parse, persisted to Application Support.

* **Live quota (best-effort, never fails refresh):** `MuseQuotaClient.swift:161`
  `POST https://api.meta.ai/v1/responses` `{model:"muse-spark-1.3-contributor",
  store:false, stream:true, input:"hi"}` with `Authorization: Bearer <api_key>`,
  `Accept: text/event-stream`, parses the first `event: response.subscription_usage`
  SSE event (`MuseQuotaClient.swift:140` `parseUsageEvent`) →
  `subscription:{tier, weekly:{used_percent,resets_at}, window:{used_percent,resets_at,
  window_duration_mins}}` → `MuseQuotaUsage` → `quotaLines:239` (`Session` `used`
  /100 `resetsAt`/`periodDurationMs` 5h default, `Weekly` 7d). `MuseProvider.swift:99`
  `fetchQuotaBestEffort()` prepends those lines before spend tiles; on any error
  it logs `AppLog.warn` and the local scan stands alone.

## 2. Prior behavior (committed `0c951fe`/`57626d4`)

* `MuseAuthStore.swift` only checked `META_API_KEY` env or non-empty `auth.json`
  (`MusePaths.authFilePath` via `MUSE_CONFIG_DIR`/`XDG_CONFIG_HOME`/`~/.config/muse/auth.json`
  or `MUSE_AUTH_PATH`). Presence only, never the secret.
* `MuseUsageScanner` + `MuseProvider` + `ProviderCatalog` + `DefaultLayout` + `pricing_supplement.json`
  shipped logs-only: no quota, no plan badge.

## 3. What changed (uncommitted in this handoff)

* `MuseQuotaClient.swift` (new, `Sources/OpenUsage/Providers/Muse/MuseQuotaClient.swift:47-315`):
  `keychainService="ai.meta.dev.credentials"`, `account="meta"`,
  `userConfigPaths=["~/.config/openusage/muse.json"]`, `userEnvironmentNames=["META_API_KEY"]`.
  Added `MuseKeychainMemo` (`NSLock` + `value/isSet`, `getIfSet()->String??`) as
  `private let keychainMemo` on the client (instance-scoped, so struct copies share
  the memo; fresh instance per test avoids cross-test pollution).

* `MuseAuthStore.swift` now maps `UserAPIKeyStore.Failure` → `MuseUsageError`
  (`apiKeyMissing`/`apiKeySaveFailed`/`apiKeyDeleteFailed`) and documents that the
  quota bearer lives in `MuseQuotaClient`.

* `MuseProvider.swift:46-49` now exports `Session`/`Weekly` as limits
  (`.exportingLimit("session",unit:"percent")`), and `MuseProvider.swift:99`
  `fetchQuotaBestEffort` + `planNameOverride`.

* `ErrorCategory.swift` maps the new `MuseUsageError` cases.

* `MuseQuotaClientTests.swift` / `MuseUsageScannerTests.swift` deltas for the new
  parsing and `provider.refresh()` integration.

* `script/build_and_run.sh` / `embed_sparkle.sh` detritus fix (unrelated).

## 4. The single password prompt — what the maintainer should know

* `~/.config/muse/auth.json` on a normal install is `{"providers":{"meta":{"storage":"keychain"}}}`,
  not the secret. The real `api_key` lives in the macOS keychain JSON blob
  (`security find-generic-password -a meta -s ai.meta.dev.credentials -w` →
  `{"secret_schema_version":1,"api_key":"LLM|…","access_token":"dca:…"}`).

* Before this fix `MuseQuotaClient.apiKey()` did a fresh `security` exec on every
  `WidgetDataStore` refresh (≈5 min). When the login keychain auto-locks, each
  exec prompts for password/Touch ID.

* Now `apiKey()` (`MuseQuotaClient.swift:122`) is:

  ```swift
  userStore.loadKey() // ~/.config/openusage/muse.json (JSON apiKey/api_key/key or plain text) > META_API_KEY env
  ?? memo.getIfSet()  // in-process
  ?? security blob → parse api_key → memo.set → if userStore.keyStatus()==.notSet { try? userStore.saveKey(key) }
  ```

  The `security` read is memoized in-process (`NSLock`), so at most one prompt
  per launch. On first success it is best-effort persisted to the app-owned file
  `~/.config/openusage/muse.json` (`0600` via `LocalTextFileAccessor.writeText`,
  atomic `open(O_CREAT|O_EXCL|O_NOFOLLOW,0600)` + `fchmod` + `fsync` + `rename`).
  Next launch `userStore.loadKey()` hits the file before the keychain, so zero
  prompts. `userStore.keyStatus()` flips `notSet` → `saved`, status dot goes green,
  Settings shows `Saved in App` with reveal/clear. `try?` never overwrites an
  explicit file/env choice (`keyStatus()!=.notSet` skips).

* First `security` failure (locked/denied) is cached as `nil` and re-thrown once
  so `fetchQuotaBestEffort:154` logs `quota probe failed…` once; subsequent polls
  hit memoized `nil` silently (Go's `museAPIKeyCache` does `ok=false` similarly).

* Rotation: a stale file causes `401` → `MuseQuotaError.unauthorized` (`api_key`
  rejected). The user clears it in Settings (`deleteAPIKey`) or deletes the file;
  next successful keychain read re-seeds it. No automatic overwrite on 401.

* A GUI app launched from Finder/Dock doesn't inherit the shell env, so
  `ProcessEnvironmentReader` also checks the captured login-shell snapshot for
  `META_API_KEY`; `LocalTextFileAccessor` handles `~` expansion and `0600`.

## 5. Quota edge case — exhausted subscription

When `Everyday Usage` is exhausted the probe returns

```
HTTP 429 {"error":{"code":"rate_limit_exceeded","message":"Subscription quota exhausted. Your usage window resets at 2026-09-14T00:00:00Z.","resets_at":1789344000}}
```

instead of the SSE stream. `MuseQuotaClient.swift:180` now treats `429` with
`code==rate_limit_exceeded` and `message` containing `quota` (case-insensitive)
as quota, not a transient error: it parses `resets_at` and returns
`MuseQuotaUsage(weeklyUsedPercent:100, windowUsedPercent:100, weeklyResetsAt:resetsAt,
windowResetsAt:resetsAt, windowDurationMins:300)`. `quotaLines` then renders
`Session 100%`/`Weekly 100%` with reset Sep 14, so `GET /v1/limits/muse`
(`LocalLimitsAPI.swift:70` via `limitResources` on the two `percent` descriptors)
shows `resources:{session:{used:100,limit:100,resetsAt:…}, weekly:{…}}`
instead of `resources:{}` `stale:true`. Generic `429` without `quota` still throws
`requestFailed(429)` and falls back to local spend.

## 6. Limits export

`MuseProvider.swift:48-49` now `exportingLimit("session"/"weekly", unit:"percent")`,
so `LocalLimitsAPI.WireProvider:70` finds the `Session`/`Weekly` `progress` lines
and emits `WireResource{key:session/weekly, kind:consumption, unit:percent,
used/limit/remaining/utilization/resetsAt/windowSeconds}` for `GET /v1/limits`
and the `openusage` CLI.

## 7. Testing

* `swift test --filter MuseQuota` 13 tests, `MuseQuotaProviderTests` 4 tests,
  `MuseUsageScannerTests` 12 tests — all green. Each test creates a fresh
  `MuseQuotaClient` (`FakeKeychain`/`FakeFiles`/`FakeEnvironment` in
  `TestSupport.swift:283`/`259`/`247`), so memo starts empty.
* Manual: first `security find-generic-password` creates `~/.config/openusage/muse.json`
  `0600`, second `WidgetDataStore` refresh shows `Session`/`Weekly` with no second
  `security` exec (verified via `log`); `curl /v1/limits/muse` after exhausted-quota
  fix shows `session`/`weekly` 100 with `resetsAt:2026-09-14T00:00:00Z`.

## 8. Branch / PR status

Branch `feat/muse-code-provider` on fork `tomck/openusage` is at `57626d4`
(`origin/feat/muse-code-provider` up-to-date). The quota client + memo + 429
handling + `exportingLimit` are local unstaged/untracked changes
(`MuseQuotaClient.swift`, `MuseQuotaClientTests.swift`, `MuseProvider.swift`,
`MuseAuthStore.swift`, `ErrorCategory.swift`, `script/*`, `SPARKTHINKING.md`,
`docs/providers/muse 2.md`). No PR has been opened by an agent yet
(`no agent opened pull requests`). To open a PR:

```bash
git -C openusage add Sources/OpenUsage/Providers/Muse/MuseQuotaClient.swift \
  Tests/OpenUsageTests/MuseQuotaClientTests.swift \
  Sources/OpenUsage/Providers/Muse/MuseProvider.swift \
  Sources/OpenUsage/Providers/Muse/MuseAuthStore.swift \
  Sources/OpenUsage/Providers/ErrorCategory.swift \
  docs/providers/muse.md  # if you update it
git commit -m "Add Muse Code live quota (Responses SSE) with single-prompt keychain memo"
git push origin feat/muse-code-provider
gh pr create --repo robinebers/openusage --base main --head tomck:feat/muse-code-provider
```

Update `docs/providers/muse.md` to mention Session/Weekly meters and the
single-prompt file at `~/.config/openusage/muse.json` before opening.
