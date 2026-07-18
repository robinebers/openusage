# Account-First Multi-Account Plan

The execution plan for multi-account Claude/Codex support, replacing the closed PR #1014
(branch `claude/provider-management-ux-780d96`, continued on `agent/multi-account-cli-pr1014`).
Those branches stay alive as **cherry-pick material** — most of their auth-store scoping, discovery
internals, swap timeline, iCloud remapping, and ~4k test lines port into the phases below.

## Why the restart

PR #1014 keyed the default card by *location* (the default home) and every extra account by
*identity*. Review traced nearly every P1 bug to that split: the default card's identity is mutable,
so the branch accreted ~1.5–2k lines of guard machinery (same-account folds, duplicate suppression,
launch gating, history withholding) defending a structural flaw — guards its own follow-up plan
would then delete. Since none of it ever shipped, no user has state that needs the staged
migrate-shadow-flip choreography. This plan flips to the account-first model **before** any
multi-account discovery ships, so the guards never get written.

## Target model

Every card is an **account**: an opaque identity key with a stable record id minted at creation.
Places an account is signed in are **sources** (default home, config dir, cswap vault slot,
Desktop/Cowork, Codex home) attached to its record. "Default" is a badge on a source
(`holdsDefaultSource`) used for the bare-id alias, CLI resolution, and attribution — never a key,
never live sort order. A swap re-points source edges; cards, history, layout, and pins never move.
An unresolved source claims no account. A card whose sources are all absent renders a calm
signed-out state with a Remove affordance (tombstone; rescans never resurrect it).

### The migration-killing decision

The account occupying the default home at conversion time **keeps the bare id (`claude`, `codex`)
as its permanent record id**. Ids are opaque, so nothing is special about the shape. Every existing
install migrates by doing nothing: layout keys, pins, history bindings, snapshot cache entries, and
third-party API consumers keep working untouched. If the user later swaps accounts at the default
home, the new account mints `claude@<hash8>` and takes the default badge; the old card stays under
its old id. The bare id doubles as the family **alias**: requests for `claude` resolve through
`ProviderCardResolver` (badge holder → sole enabled family card → family empty state) and the HTTP
API echoes the requested id.

## Phases

Each phase is one PR, shipped to the **beta channel** and soaked before the next starts. Docs and
tests land in-slice (repo policy). Estimated source LOC excludes tests.

### Phase 0 — Standalone reliability (no model change, ~300 LOC)

- Shell-environment snapshot: discovery-grade env facts survive a slow login shell
  (cherry-pick `22c8e97`).
- File splits along provider seams where they help review (`c96fc75`, as needed).
- Exit: beta with zero behavior change beyond launch reliability.

### Phase 1 — Account-first core, single account per family (~800 LOC)

- `ProviderAccountsStore` (`openusage.providerAccounts.v1`): account records with id, family,
  identityKey, label, sources (+ badge), tombstone. Port from `e052ef9`, dropping the
  shadow-comparison half — the registry is authoritative from day one.
- Default-home identity reading for Claude and Codex (the proven slice of discovery — **no
  candidate scanning yet**). Resolved identity attaches the default source; unresolved leaves the
  family rendering its current state.
- Cards render from account records. With exactly one account per family this is pixel-identical
  to today, so the structural flip ships invisibly.
- `ProviderCardResolver` wired through the one-shot CLI and local HTTP API (port from `e052ef9`).
- Snapshot-cache identity stamp (v9): cached values remember the producing account; a swap between
  launches discards the stale entry instead of painting it under the new account (port `fef9ad0`).
- Signed-out rendering + "Remove Account…" (context menu, tombstone in the store) — cheap while
  the model is small.
- Exit: beta soak; logs confirm identity-resolution rates in the wild; existing users see nothing.

### Phase 2 — Claude multi-account: config-dir discovery (~1,200 LOC)

- Candidate scan (dot-dirs at `~`, dirs under `~/.config`), identity-extraction-is-validation,
  support-trail log lines. Port the discovery internals; **omit** fold/suppression plumbing — a
  candidate naming a known account just attaches as another source/log root on that record, so
  duplicate cards are structurally impossible.
- New account → new record → new card named by account label ("Claude — Sunstory"); layout seeded
  from `DefaultLayout.translatedForInstances` (pins never seeded).
- Scoped `ClaudeAuthStore` (per-config-dir keychain names), per-account spend from each home's logs.
- iCloud identity routing: `PeerHistoryRemapper`, account-identity matching, v1-peer histories to a
  family bucket rendered as device-labeled remote-only slices. Required the moment two accounts can
  exist.
- Exit: beta soak with real multi-config-dir users; lifecycle test suite re-targeted green.

### Phase 3 — Claude: Cowork / Desktop accounts (~500 LOC)

- Cowork sandbox walk with per-sandbox identity; sandboxes matching an existing account attach as
  its log roots; a distinct account becomes one Desktop-backed card (org-pinned identity, Safe
  Storage credentials).
- Purely a new source kind on the existing model.

### Phase 4 — Claude: cswap (~500 LOC)

- Vault slot discovery: each parked slot is a source of its account; the active slot is whoever
  holds the default badge.
- Switch-log timeline partitions the shared home's spend logs per account.
- A swap is the badge moving between records — no suppression, no restart requirement. A
  mid-process swap marks the source stale; reconcile next launch.

### Phase 5 — Codex multi-account + per-card resets (~700 LOC)

- **5a:** `CODEX_HOME` candidate scan with the strict identity rule — `tokens.account_id` or the
  id_token's ChatGPT account claim; a credential file that can't name its account never becomes a
  card (port `93e741e`). Scoped auth stores, per-identity log-root grouping, and the
  `CodexResetClaimRouter` (port `b6be1b1`) so every account's row claims its own reset credits from
  day one.
- **5b (separate if needed):** keyring-mode homes — an unverified keyring source claims no account
  until the one-time post-launch account-scoped read binds it (`CodexHomeIdentityCache`). The
  nichest slice; keeping it out of 5a keeps 5a simple.

### Phase 6 — Attribution polish (small)

- Pi spend attribution routed through the resolver to the badge holder.
- Family-keyed telemetry rollups (`accounts_per_family` gauge).
- Total Spend family grouping/tinting if still wanted (see `c6a63eb` on the old branch for why
  plain size order won before).

## Owner decisions (lock before the phase that needs them)

1. **Bare id as the first account's record id** — the plan assumes yes (kills all migration).
2. Label fallback when an account has no email/org name: short hash vs ordinal ("Claude 2").
3. Newly discovered accounts seed enabled (PR #1014 behavior) or disabled.
4. Remove-button placement: context-menu-first (assumed), Customize section later.

## Verification

- Per phase: `swift build` + full `swift test`; new suites land with their phase.
- Live: `script/build_and_run.sh`, then `~/Library/Logs/OpenUsage/OpenUsage.log` — discovery trail,
  identity resolution, and (Phase 1+) account-registry lines.
- Beta release per phase via the release-swift skill; soak before the next phase merges.
- CLI/API: `openusage claude` (alias) and `openusage claude@<hash>` (direct);
  `curl 127.0.0.1:6736/v1/usage/claude` echoes the requested id.
- iCloud: two-machine check once Phase 2 lands (migrated writer + old reader and inverse).
