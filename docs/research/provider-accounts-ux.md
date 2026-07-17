# Provider Accounts UX — Research & Design Angles

Research date: 2026-07-16. Status: proposal, no decision yet.

The goal: one machine, several logins of the same provider (work + personal Claude, two Codex homes), each shown as its **own provider** in OpenUsage — its own card, its own pins, its own enable state — with add/remove UX so obvious that a first-run user thinks "it just works," exactly like today's installed-tool detection.

## 1. Where we've been

Three attempts shape the constraints:

- **Issue #402** (approved): asked for first-class `provider × account` instances with display names, per-account usage, and graceful hiding of removed accounts. The issue sketched account *rows under one provider heading* — the aggregation UI we now explicitly do not want.
- **PR #965** (community, closed): scanned `~/.claude*` dirs and `Claude Code-credentials*` keychain items, minted synthetic per-account provider ids (`claude.<uuid>`). Right instinct (accounts as instances), wrong execution: the synthetic-id convention leaked into layout, enablement, telemetry, and every id-keyed surface with no migration story.
- **PR #987** (ours, WIP, to be abandoned): the opposite trade. Accounts became first-class *records* (`ProviderAccount` = UUID + credential address + custom name; the default login stays the bare provider id, extras get `providerID@uuid` account keys), but the UI is a **header caret picker that swaps one shared card** between accounts. No persistence migration needed — because layout, pins, and enablement deliberately stay per-provider — but that is precisely the "shared" model that feels wrong: you can't see work and personal at once, pins follow an invisible selection, and the mental model ("which login is this card showing right now?") requires thinking. The complexity shows in Bugbot's six unresolved findings: a process-wide keychain-interaction gate that races under concurrent per-account refresh, a reset-claim service bound to a stale runtime map, selections dangling after account collapse, removed accounts that keep refreshing. A selection layer projected over shared surfaces breeds exactly this class of bug.

### What #987 taught us about discovery (hard-won, keep these lessons)

- **Keychain enumeration is a junk swamp.** Every one-shot `CLAUDE_CONFIG_DIR` login (agent sandboxes, CI-ish runs) mints a suffixed `Claude Code-credentials-<hash>` item that never gets cleaned up. #987 needed heuristics (modification date must move >24h past creation; prune unnamed records that discovery stops returning) just to not show 160 ghost accounts.
- **Keychain ACLs can freeze launch.** Attribute-only enumeration is prompt-free, but any *secret read* can block behind a hidden ACL dialog; `LAContext`/`kSecUseAuthenticationUIFail` do **not** stop the file-based login keychain from blocking. Shipped discovery therefore stays attributes-only and bounded; an unverified Codex home is hidden, then one retained post-launch task performs its exact account-scoped read and may show the normal one-time permission dialog.
- **Codex keychain shape is known**: one `Codex Auth` service, account `cli|<first 16 hex of SHA-256 of the canonical home>`; keyring mode deletes `auth.json`. A home dir and its hash-matched keychain item are the *same* account and must collapse.
- Claude Desktop orgs are readable via Electron safeStorage (#962), read-only, with a one-time Safe Storage keychain grant that must happen on a user action, never at launch.

## 2. Ground truth from a real multi-tool Mac (2026-07-16)

Forensics on the owner's machine — a heavy multi-agent setup, i.e. the adversarial case for auto-discovery:

| Signal | Found | Verdict |
|---|---|---|
| `Claude Code-credentials*` keychain items | **178** (one unsuffixed real item, `acct=rebers`, touched today; the rest suffixed one-shots) | Enumeration alone is ~99% junk here |
| `Codex Auth` keychain item | 1 (`cli\|601b0021…`, last modified 2026-04-28 — stale next to a live `~/.codex/auth.json`) | File vs keychain freshness must be reconciled |
| Sibling home dirs (`~/.codexcode`, `~/.openclaude`, `~/.opencode`, `~/.factory`) | 4 lookalikes, **zero** contain Claude/Codex credentials — two are the owner's toy projects (`.codexcode` = own log format, `.openclaude` = empty settings stub), one is a real product's *install* dir (`.opencode` — OpenCode's data actually lives in `~/.local/share/opencode`), one is a real product's stub (`.factory` = droid, empty settings) | Dir *names* mean nothing — real products, toys, and installs all collide; only credential **shape + identity** validation separates them |
| `CLAUDE_CONFIG_DIR` / `CODEX_HOME` in shell rc files | none | Deliberate multi-home users export these; absence here = single-account truth |
| Switcher registries (cc-switch etc.) | none | When present, these are user-curated account lists — the best possible signal |
| Identity available without keychain | `~/.claude.json` → `oauthAccount` (emailAddress, displayName, organizationName, organizationUuid, accountUuid, seatTier, rate-limit tiers); `~/.codex/auth.json` → `tokens.account_id` + id_token JWT claims | Dir-backed accounts are **self-identifying, prompt-free** |
| Claude Code 2.1.210 native multi-account | single `oauthAccount` object, no profile registry | No native switcher to lean on (verify against changelog) |

The honest read of this machine: **one real Claude account, one real Codex account** — and any design that would have shown more than that here is wrong. The corollary: a *deliberate* second account essentially always lives in a second config home (you cannot run two logins out of one dir), is self-identifying via its own `.claude.json` / `auth.json`, and is distinguishable by account identity, not by path.

## 3. What the codebase assumes today — and what it already gives us

From a full trace of provider identity through `main` (file:line refs are current worktree):

**The singleton assumption is an id-string convention, not deep architecture.** `Provider.id` is a plain string that doubles as the literal prefix of every descriptor id (`"claude.session"`, built in `WidgetDescriptor+Factories.swift:105`). Everything downstream keys on those two string families:

- `DefaultLayout.swift` hardcodes descriptor-id literals for enabled/pinned/expanded defaults (`:9-36`, `:61-69`, `:76-104`).
- `LayoutStore` persists provider order, per-provider metric order, pinned/expanded descriptor ids under `openusage.layout.v1.*` (`LayoutPersistence.swift:86-95`); pin cap is per provider id (`LayoutStore.swift:264-285`).
- `ProviderSnapshotCache` (`openusage.providerSnapshots.v8`) keys by providerID (`:76-113`).
- `ProviderEnablementStore` keeps enabled/known provider-id sets (`:25-27`); `FirstRunSeeder`/`NewProviderSeeder` probe by id.
- Local HTTP API exposes `/v1/usage/<provider>` with the bare id as public URL segment (`LocalUsageAPI.swift:65-70`).
- Telemetry counters, menu-bar pin grouping, iCloud history documents, and `CodexResetClaimService` (bound to *the* single `CodexProvider`, `AppContainer.swift:116`) all assume one instance per id.

So "accounts as individual providers" is fundamentally an **id-migration problem**: mint per-instance ids properly (with the default instance keeping the legacy bare id so existing installs migrate for free), or leak synthetic ids like #965 did.

**Already-built machinery that points the way:**

- Both spend scanners **already support multiple homes**: `CLAUDE_CONFIG_DIR` and `CODEX_HOME` accept comma-separated lists (`ClaudeLogUsageScanner.swift:86`, `CodexLogUsageScanner.swift:86`) — today aggregated into the single card. The multi-home reading exists; only the identity split is missing.
- PR #975 (pi fold-in) established the *other* multi-home pattern: a second usage source merged into an existing card via `DailyUsageAccumulator.merged` with no double counting. Aggregation-into-one-card and instance-splitting are both available as primitives, per source.
- Account identity is on disk but unread: Claude's CLI credential blob has **no email/org** — identity lives next door in `<config-dir>/.claude.json` → `oauthAccount` (email, display name, org, account UUID, tiers), which nothing reads today. Codex's `auth.json` carries `tokens.account_id` (already sent as the `ChatGPT-Account-Id` header, `CodexUsageClient.swift:85`) and an `id_token` JWT whose email/plan claims are parsed only for `exp` today (`CodexAuthStore.swift:176-181`).
- The enablement store already has the exact "removed things stay removed" semantics we need for accounts: a provider absent from Enabled but present in Known is a deliberate off-choice that no update or re-detection ever flips back (`docs/provider-enablement.md`); only "Reset All Customization" re-runs detection. Account tombstones can reuse this pattern verbatim.

## 4. Ecosystem survey

### 4.1 Claude: no native multi-account; the account unit is (again) a directory

- Claude Code v2.1.210 has `auth login|logout|status` only — no switch, no profiles, no saved accounts. `/login` *replaces* the stored account (anthropics/claude-code#23906). Multi-account is a top community request (#24963 at 67 👍, #30031 at 61 👍, #27359, #22872) with nothing shipped per the changelog. A recent fix note ("parallel sessions all logging out simultaneously… when many sessions share one credential store") confirms the one-credential-store model.
- `CLAUDE_CONFIG_DIR` moves the whole profile: the dir gets its own `.claude.json` (with `oauthAccount` identity), its own `projects/` logs, and its own keychain entry `Claude Code-credentials-<hash8>` — the suffix formula (first 8 hex of SHA-256 of the dir path) is already implemented in our own `ClaudeAuthStore.hashSuffix` (`ClaudeAuthStore.swift:491`). So **given a dir we can compute its keychain service name directly — no enumeration ever needed.**
- `claude auth status --json` emits `{loggedIn, authMethod, email, orgId, orgName, subscriptionType}` — a token-free identity probe if we ever want CLI-assisted naming; but `oauthAccount` in the dir's `.claude.json` already gives us email/org/tiers with a plain file read.
- Claude's local JSONL logs contain **no identity fields whatsoever** (verified across 267 files: cwd/session/git only). Same conclusion as Codex: logs are attributable to an account only via the directory they live in — and per-dir logs make per-account spend *free* when accounts are dir-isolated.
- How real users run two accounts: shell aliases (`alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'` — the canonical recipe), direnv per folder tree, parallel terminals. The heavier fallbacks (containers, separate macOS users) exist precisely because nothing native helps.
- Switcher ecosystem splits into two philosophies with different consequences for us:
  - **Swap-in-place vaults** (claude-swap/`cswap` ~1.1k★ with backups in `~/.claude-swap-backup/`; Symbioose claude-account-switcher with `~/.config/claude-switcher/accounts.json` + `claude-switcher:{email}` keychain items; CCSwitcher `~/.ccswitcher/backups.json`; caam vault `~/.local/share/caam/vault/<tool>/<profile>/`): one active account in the default home, others parked in the tool's vault. Note: these users' `~/.claude/projects` logs **mix accounts over time** — historical spend can't be attributed retroactively no matter what we do.
  - **Config-dir isolation** (manual `CLAUDE_CONFIG_DIR` setups): N accounts genuinely parallel, each self-identifying — the clean shape for us.
  - Aside: cc-switch (the 117k★ giant) switches API *endpoints/relays*, not subscription accounts — not our problem space, but its scale shows how starved this need is.

### 4.2 Codex: the account unit is a directory, and nothing enumerates them

- `CODEX_HOME` is the whole story: one home = one login (`auth.json`), and the path must pre-exist when the env var is set. Official multi-account is **not planned** — openai/codex#26014 closed NOT_PLANNED; #4432 (`--auth-profile`), #30684 (account switching), #14330 (per-account env isolation) all open. Every real-world workaround is "one CODEX_HOME per account" via shell aliases, wrapper scripts, or swap-auth.json helpers (codex-auth, codex-acc, aisw…).
- **Codex writes no global registry.** All state is home-contained; the only outside-home artifacts are an opt-in keyring entry (service `Codex Auth`, key = SHA-256-derived hash of the canonical home path — reveals *that* homes used keyring mode, not *where* they are) and an account-free plugin cache. **There is no on-disk way to enumerate all Codex homes on a machine.**
- **Session logs carry no account identity.** `session_meta` has session/thread ids, cwd, originator, cli_version, git info — no account_id, no email, no home path. `history.jsonl` is `{session_id, ts, text}`. The "go through logs to find hints of other homes/accounts" angle is a dead end for Codex: logs can't even be attributed to an account after the fact. (Per-home attribution works only because each home has its own `sessions/` dir.)
- **Identity is cheap once you have the home:** decode `tokens.id_token` → `email`, `chatgpt_plan_type`, `chatgpt_account_id`, org list — all offline, no network, no keychain.
- Watch item: `cli_auth_credentials_store = keyring|auto` (default `file`) moves auth out of `auth.json`; a file-only reader sees the account "disappear" while Codex still works. The keyring key is computable from the home path, so a *dir-anchored* reader stays correct — another point for dirs-as-anchors.

### 4.2 Prior art: CodexBar is the only one that shipped it — three different models at once

CodexBar (steipete, ~18k stars) is the most developed prior art and effectively ran the experiment for us:

- **Codex "managed accounts"** (their default): CodexBar creates a full CODEX_HOME per account under `~/Library/Application Support/CodexBar/managed-codex-homes/<UUID>/`, runs the official `codex login` against it, and keeps a registry (`managed-codex-accounts.json`: email, workspace, auth fingerprint, home path). Switching "promotes" a managed auth into the live `~/.codex` with careful preserve-the-displaced-account semantics. Notable: **login happens through the provider's own CLI**, not a custom OAuth client — the app owns directories, never the OAuth flow.
- **Codex "advanced profile-home accounts"**: users list *existing* homes (`codexProfileHomePaths` in its config); each must contain `auth.json`; CodexBar reads identity from the file and scopes fetches by setting `CODEX_HOME` in child env. Read-only adoption of homes the user already made.
- **Claude**: deliberately **not** a credential vault — an opt-in adapter over the external `claude-swap` switcher (`cswap --list --json`), read-only stacked cards. Their design doc's option matrix explicitly **rejected keychain-entry enumeration** and deferred a first-party vault — independent convergence with our §2 forensics. This is also exactly the "third-party switcher" dependency we consider a hack: it works only for users who already adopted that one tool.
- **Cursor**: per-account cookie web sessions (`WKWebsiteDataStore`) — a path OpenUsage cannot take (hard no-cookie constraint).

Nobody else has it: VibeMeter (multi-account open issue; misses even custom `CLAUDE_CONFIG_DIR`), CCSeva / Claude usage monitors (single-dir assumptions). ccusage is the *aggregation* precedent only: comma-separated `CLAUDE_CONFIG_DIR`, merges dirs, no account concept.

### 4.3 The dotdir landscape: why validation must be schema-exact, not name-based

A survey of what actually creates dotdirs on 2026 dev machines (primary sources: each product's repo/docs):

| Product | Dir | Collides with `~/.claude*`/`~/.codex*` glob? | Credential shape there |
|---|---|---|---|
| claude-code-router | `~/.claude-code-router/` | **yes** | router config + third-party API keys (SQLite) — not OAuth+identity |
| claude-squad | `~/.claude-squad/` | **yes** | program config JSON — no credentials |
| CodexBar | `~/.codexbar/` | **yes, on a loose glob** | its own config; it *reads* `~/.codex` |
| Gemini CLI | `~/.gemini/` | no | `oauth_creds.json` — **shape-twin of an OAuth blob** (access/refresh/id_token/expiry_date) |
| Qwen Code | `~/.qwen/` | no | `oauth_creds.json` — same shape-twin caveat |
| OpenCode | `~/.opencode/` (install) + `~/.local/share/opencode/` (data) | no | per-provider `auth.json` map (+ transitional `account.json`, see below) |
| Factory droid | `~/.factory/` | no | `settings.json` (+ custom-model keys); login-token path undocumented |
| Copilot CLI | `~/.copilot/` (`COPILOT_HOME`) | no | keychain, plaintext fallback in `config.json` |
| Cline CLI | `~/.cline/` (`CLINE_DATA_DIR`) | no | provider-key map (`providers.json`/`secrets.json`) |
| Cursor CLI, Warp, Zed, Goose | `~/.cursor`, `~/.warp`, config dirs | no | keychain — no file to collide |
| Continue CLI | `~/.continue/` (`CONTINUE_GLOBAL_DIR`) | no | `auth.json` — but WorkOS session shape |
| Augment auggie | `~/.augment/` | no | `session.json` `{accessToken, tenantURL}` |

Three conclusions:

1. **Prefix globs are meaningless in both directions.** They catch real non-Claude products (`claude-code-router`, `claude-squad`), user toys (`~/.codexcode`), and app configs (`.codexbar`) — while a real second home can be named anything (`~/work-claude`). Candidate *generation* can stay cheap and broad (all of `~/.*` plus `~/.config/*`, bounded depth); candidate *acceptance* must be schema-exact.
2. **The schemas are exact enough.** A Claude home = `.credentials.json` (or the dir's *computed* keychain item) with `claudeAiOauth.{accessToken,…}` **plus** a companion `.claude.json` whose `oauthAccount` yields email/org/UUID. A Codex home = `auth.json` with nested `tokens.{id_token,access_token,refresh_token,account_id}` + `last_refresh`, and the id_token JWT decodes with OpenAI's issuer and `chatgpt_*` claims. Gemini/Qwen's flat `oauth_creds.json` (`expiry_date`, no `tokens.*`, no `account_id`), Continue's WorkOS session, Augment's `{accessToken, tenantURL}`, OpenCode's per-provider map, Goose's `~/.config/goose/chatgpt_codex/tokens.json` (real ChatGPT OAuth, but flat and file-named differently) — none pass. Content-sniffing is expressly out: `OPENAI_API_KEY=` strings legitimately live in `.env` files across `~/.qwen`, `~/.gemini`, `~/.aider.conf.yml`, etc. Identity extraction *is* the validation: if we can't name the account, it isn't one.
3. **The instance model generalizes.** Half the roster has a config-dir override env var (`COPILOT_HOME`, `CLINE_DATA_DIR`, `CURSOR_CONFIG_DIR`, `OPENCODE_DATA_DIR`, `CONTINUE_GLOBAL_DIR`, `VIBE_HOME`…) — "home = account instance" is becoming the ecosystem-wide convention, so the anchor abstraction pays for itself beyond Claude/Codex.

**The harder truth: authentic homes exist inside other apps' storage.** The biggest generators of *shape-perfect* Claude/Codex homes aren't forks faking files — they're per-account launchers that point the **real** CLI at an app-owned dir and let it write **real** credentials there: cc-subscription-switch (`~/.cc-subscription-switch/accounts/<name>/`), ccs profiles, CodexBar's managed homes (`~/Library/Application Support/CodexBar/managed-codex-homes/<UUID>/`), cc-mirror variants — and every ephemeral agent-sandbox `CLAUDE_CONFIG_DIR`. These pass any shape check *because they are real accounts*. Three consequences for the validator:

- **Identity dedupe is also the junk filter.** Sandbox/tool-created homes almost always authenticate the *same* account as the default; keying instances by account identity means they merge into the existing instance instead of ever appearing as a second tile. Only a genuinely distinct login can surface — which is exactly the set we want.
- **Same account, several homes = one instance, several sources.** A fork home like `~/.code` (`just-every/code` writes a byte-exact Codex `auth.json` under `CODE_HOME`) or a second dir logged into the same ChatGPT account isn't a new account — it's another usage source for the same instance. The spend scanners already accept comma-separated home lists, and #975 built the merge machinery; the instance model just formalizes when to merge (same identity) vs split (different identity).
- **Known-tool-owned paths get attribution, not silent auto-add.** A home under another app's storage (CodexBar, cc-subscription-switch, …) is a deliberate account but *managed elsewhere* — surface it as a suggestion labeled with its manager ("managed by CodexBar"), one click to add.

Filename-only probes would also false-positive on pi (`~/.pi/agent/auth.json` — a provider-keyed map, no `tokens.*`) and OpenClaw's legacy `~/.openclaw/auth.json` (its own profile format); schema-exact content checks reject both. And candidate generation must stay bounded to `~` top-level and `~/.config` — never temp dirs or project trees, where sandbox homes breed.

**OpenCode caveat (corrected after source verification):** this machine's `~/.local/share/opencode/account.json` looks like a native multi-account registry — `accounts.<id>.{serviceID, description, credential}` slots plus an `active` per-provider map — but that file is a **transitional June-2026 format that no longer exists in current sst/opencode HEAD**. Current OpenCode keeps `auth.json` as the single-active-credential-per-provider store, with a separate cloud-account system in SQLite. So: treat `auth.json` as authoritative, don't build on `account.json`, and revisit if upstream lands real multi-account. The scoping rule stands regardless: the `openai`/`anthropic` entries inside OpenCode's store are its *upstream* logins (the same ChatGPT/Claude subscriptions through a different harness) and must **not** surface as extra Codex/Claude accounts — no double counting, and their usage already shows on OpenCode's own card.

**One more shape-check limit worth naming:** wrapper setups that point the real Claude Code at another backend (Z.ai/GLM/Kimi "use Claude Code with our API" recipes) can produce a conforming `claudeAiOauth` blob whose token isn't an Anthropic token. Two natural guards: the identity requirement (an env-redirected dir usually has no `oauthAccount` → never becomes an instance) and the existing fail-loud usage call (a foreign token 401/403s visibly instead of silently showing wrong data).

### 4.4 The rest of the roster

- **GitHub CLI / Copilot**: the one provider with a native, enumerable multi-account store — `~/.config/gh/hosts.yml` has a `users:` map plus active `user:` pointer since gh 2.40 (`gh auth switch`). Multi-account Copilot is essentially free to read.
- **Gemini CLI**: single active credential; `google_accounts.json` tracks `{active, old[]}` emails but no creds for old accounts; multi-account closed NOT_PLANNED (gemini-cli#16447).
- **Antigravity**: single keychain identity (service `gemini`, account `antigravity`); no per-account entries.
- **Cursor**: one credential set in `state.vscdb` (`cursorAuth/*` incl. `cachedEmail`); no native multi-account; community "switchers" swap DB rows.
- **Factory / droid** (relevant sibling, not an account source): `~/.factory` is a real product home (settings, MCP config, per-project session JSONL like Claude's) but auth is WorkOS via system keyring with encrypted-file fallbacks (`auth.v2.file`/`auth.v2.key`; the legacy v0.6 OpenUsage plugin handled all variants) and there's **no home-override env var** — so droid is a *provider* candidate, not a multi-home account candidate. Notably, [robinebers/openusage#964](https://github.com/robinebers/openusage/issues/964) ("Add Factory Droid usage provider") is open with a complete contributor implementation awaiting approval; the modern quota model (5h session window, weekly/monthly, Droid Core, Extra Usage balance) is documented there. Separate track from accounts work.

## 5. UX precedents worth stealing (and one policy verdict)

The strongest analogies are apps that *link* accounts they don't own:

- **Home Assistant config entries — the gold standard for "same integration, N instances."** An integration (type) can have many config entries (instances); each is a first-class card with per-entry rename, disable, delete, and — critically — **unique-ID dedupe**: re-discovering an already-added account aborts with "already configured" instead of creating a twin, and **reauth flows must update the existing entry, never create a new one**. Discovery surfaces a card that takes one click to confirm.
- **Finance aggregators (Monarch, Copilot Money, YNAB)** separate *connection* (institution login) from *account*, and their "remove" is layered: **Hide** (reversible, keeps updating) vs **forget** — with copy making clear nothing upstream is touched. YNAB's post-link "we found these accounts — pick which to add" checklist is the canonical found-your-stuff moment.
- **NetNewsWire** (read-only OSS aggregator): accounts are top-level sidebar sections; multiple accounts of the same service are explicitly allowed "provided the actual underlying account differs," and per-account **rename** is called out as the disambiguator.
- **Chrome profiles**: identity = nickname + avatar/color accent visible at all times; the color chip is what prevents wrong-account mistakes at a glance.
- **gh CLI**: additive `auth login`, `auth status` lists all with an active marker — but its acknowledged weakness is that "active" is global. A machine-wide *selection* is exactly what made #987's picker feel wrong; a read-only dashboard doesn't need an active account at all.
- **VS Code Accounts menu**: things that *consume* accounts (extensions) keep a re-pointable account preference — decoupling consumers from accounts so removal/rename never orphans settings.
- **CodexBar's zero-account-cost rule**: with 0–1 accounts the UI is byte-for-byte what it is today; multi-account chrome exists only once a second login is real.

### Own-OAuth: policy verdict (researched to June 2026)

- **Anthropic: hard no.** Timeline: sporadic "credential only authorized for Claude Code" errors from Sept 2025 → hard server-side fingerprint blocking of third-party harnesses (Jan 9, 2026) → explicit Consumer ToS clause (Feb 19, 2026): using OAuth tokens from Claude Free/Pro/Max "in any other product, tool, or service … is not permitted"; OpenCode deleted its Claude OAuth code after a legal request. Even `claude setup-token` tokens are inference-only and 403 on the usage endpoint. The June 2026 status quo: subscription usage for third-party tools is discretionary, and Anthropic's stated preference for third-party software is Console API keys. **OpenUsage's passive posture — read what Claude Code wrote, call the usage endpoint the way the ecosystem's trackers do — is the gray-but-tolerated position; owning a login flow is the banned one.** (CodexBar's exploratory alternative — burning a paid inference call to scrape rate-limit headers — is materially riskier and off the table for us.)
- **OpenAI: gray but publicly embraced** (official "Codex for Open Source" page name-checks third-party harnesses; ~10% of Codex traffic is third-party). Still unnecessary for us: reading homes covers it.
- A second, non-policy killer: **refresh-token rotation.** One durable login per credential store; a second client refreshing the same token races the CLI and logs it out. OpenUsage already deliberately never refreshes Claude tokens (issue #738 work) — an in-app login would force us into exactly the custody business we've avoided.

## 6. Design angles considered

**A. Shared card + account picker (#987).** One card per provider; a caret swaps which login fills it. *Rejected — it's the UX we built and don't want.* You can't see work and personal at once; pins follow an invisible global selection (the gh CLI weakness); the projection layer breeds races (six Bugbot findings). Retained from it: the discovery lessons, the account-record concept, per-account snapshot keying, and the Codex keychain findings.

**B. Aggregate rows under one provider (#402's original sketch, ccusage merge).** *Rejected for accounts.* Different plans/reset windows make any provider-level roll-up misleading (the issue itself enumerates why). Aggregation stays the right tool for *same-account* multi-source folding (pi, comma-separated homes) — a different problem we already solve.

**C. Own OAuth login inside OpenUsage.** *Rejected.* ToS-banned and fingerprint-enforced for Anthropic; unnecessary for OpenAI; refresh-rotation custody conflicts for both; against the product's read-only soul (same instinct as the no-cookie constraint).

**D. Keychain enumeration as discovery (#987's Claude path).** *Rejected as a discovery channel.* Ground truth on one real machine: 178 `Claude Code-credentials*` items, one real; suffix hashes can't be mapped back to dirs (one-way); junk heuristics (mdat−cdat>24h) are guesswork; secret reads can freeze launch behind ACL dialogs. Keychain stays as a **computed lookup**: given a dir we already trust, derive its item name (`hashSuffix`) and read that one item — no enumeration or heuristics. Claude reads remain refresh-driven; an unverified Codex home is hidden for one launch and gets one exact post-launch read to bind its identity cache.

**E. Third-party switcher adapters (CodexBar × claude-swap).** *Rejected as the core* — depending on someone else's tool is the "hacky shit" we're trying to beat, and it only serves users of that one tool. *Kept as optional, later:* switcher registries (`~/.claude-swap-backup/`, `~/.config/claude-switcher/accounts.json`, `~/.ccswitcher/backups.json`, caam's vault) are explicit, user-curated account lists — perfect **suggestion** sources ("claude-swap manages 3 accounts — show them?"), read-only, adapter-per-tool.

**F. Mining logs for account/home hints.** *Dead end, now proven twice.* Claude JSONL lines (verified across 267 files) and Codex `session_meta`/`history.jsonl` (verified in source) contain **no account identity and no home paths**. Neither CLI writes any global registry of homes. Logs only matter per-home: each home's `projects/`/`sessions/` dir gives that account's spend for free. The realistic "hints" live elsewhere: shell rc aliases exporting `CLAUDE_CONFIG_DIR`/`CODEX_HOME` (parseable, fuzzy → suggestion tier), and switcher registries (angle E).

**G. Credential homes as first-class provider instances.** *Recommended — see §7.*

## 7. Recommendation: accounts are credential homes, homes are providers

One sentence: **an account is a directory OpenUsage can point at; every such directory becomes a full, ordinary provider tile — detected like providers are detected today, named from its own identity file, removable without touching anything on disk.**

### 7.1 Model

- `ProviderInstance` = provider type + **home anchor** (config dir path; `nil` for the default home) + stable **account identity** read from the home (`oauthAccount.accountUuid` / `emailAddress` for Claude; `tokens.account_id` / id_token email for Codex).
- **Instance ID**: the default home keeps the bare provider id (`claude`) — zero migration, single-account users see zero change (CodexBar's zero-cost rule). Extras get `claude@<8-hex of account identity hash>` — keyed on *who*, not *where*, so a re-added or moved home converges on the same instance (HA unique-ID dedupe), layout/pins survive, and two paths to the same account collapse.
- Instance ids flow through the existing string-keyed machinery as ordinary provider ids: descriptor ids become `claude@ab12cd34.session` by the same prefix convention; `LayoutStore` order/pins/expanded, enablement sets, snapshot cache, telemetry, menu-bar grouping all work unchanged *because* the id scheme is unchanged in kind. `DefaultLayout` literals apply to default instances; extra instances copy their provider's default template at add time.
- Per-instance spend is real, not projected: each home's logs belong to that account (both CLIs), so the existing scanners run per-home. This is strictly better than #987, where extra Claude accounts read "No data" forever.
- Reuse the enablement store's proven semantics per instance: Known + Enabled sets, so **removed accounts stay removed** across rescans (tombstone by account identity), exactly like disabled providers today.

### 7.2 Detection ladder (confidence-tiered, nothing interactive at launch)

1. **Default homes** — today's behavior, unchanged.
2. **Home-shaped dirs, schema-validated** (candidates from two generators: dotdirs at `~` top level and `~/.config/*`; plus **provider-registered container walks** for known nests that don't live at `~` — the shipped Cowork scan is the precedent: `ClaudeLogUsageScanner.coworkClaudeDirs()` already walks `~/Library/Application Support/Claude/local-agent-mode-sessions/*/*/local_*/.claude` at bounded depth. Never temp dirs or project trees): a candidate counts only if it passes the **schema-exact** check from §4.3 (live credentials in the provider's exact shape — `auth.json` with `tokens.*` nesting / `.credentials.json` or the dir's *computed* keychain item) **and** yields self-identity (its `.claude.json` `oauthAccount` / decodable id_token). Then identity routing: **distinct account → new instance (auto-add); same account as an existing instance → merged as an additional usage source of that instance** (the comma-separated-homes machinery), which is also what silently absorbs sandbox homes and fork homes (`~/.code`) — they're almost always the same login. Cowork is the live proof that routing, not validation, is the real filter: on the owner's machine 344 of 346 Cowork session sandboxes carry a **full `oauthAccount` identity** (they would pass any identity check), and all of them name the same account — so they collapse into the existing Claude card, which is exactly what the spend scanner already does with them today. If Cowork/Desktop is logged into a *different* account than the CLI, identity keying yields exactly one extra instance (not 346) — and that instance should anchor its credential to Claude Desktop's own store (#962), never to an ephemeral session sandbox that cleanup will delete. Corollary rule: **ephemeral container dirs are usage sources only, never account anchors.** (Also verified: the 178 orphaned keychain items do *not* hash-match the Cowork dirs — they came from one-shot sandboxes whose folders are gone, reconfirming that suffixed keychain items can't be mapped back to dirs and that keychain-only orphans must never count as accounts.) On the owner's machine this tier correctly yields zero new instances (toys and other products fail the schema; nothing else has a distinct identity). First-run and new-login detection use this tier, `FirstRunSeeder`-style.
3. **Suggestion tier — shown as a one-click "Found …" row, never auto-added**: homes referenced by `CLAUDE_CONFIG_DIR`/`CODEX_HOME` in shell rc files (custom paths like `~/work/claude-home` that tier 2 can't see); homes living inside another app's storage, labeled with their manager ("managed by CodexBar" / cc-subscription-switch accounts); switcher-registry adapters (angle E); Claude Desktop orgs (#962 machinery — the Safe Storage grant happens on the user's click, never at launch).
4. **Manual add — the always-works escape hatch**: "Add Account…" opens a folder picker (drag-and-drop too); OpenUsage validates the shape and shows the resolved identity ("rob@sunstory.com — Max 20x") before confirming. Zero ambiguity, works for any layout we never predicted.

Nothing in tiers 1–2 reads a keychain secret or can prompt; tier 2's keychain checks are attributes-only on a *computed* item name. Claude secret reads happen on first refresh. A Codex keyring-only home is conservatively hidden, then a retained post-launch task performs one computed, account-scoped read to bind its identity for the next launch; that read can cause one predictable macOS prompt.

### 7.3 UX walkthrough

- **First run**: "Claude — rob@gmail.com" and "Claude — rob@sunstory.com" simply both appear as cards, named from their identity files, ordered default-home-first. The wow is that it *names* your accounts without being told.
- **Dashboard**: each instance is an ordinary provider section. Header shows nickname; subtitle/identity (email) lives in the header row the way plan badges do today. Optional small color accent per extra instance (Chrome pattern) for menu-bar and card disambiguation — owner call.
- **Customize L1**: instances listed as ordinary rows (reorder anywhere, master toggle each). Under each provider family with a detected-but-unadded candidate, a quiet "Found: work@co.com — Add" row (tier 3); an "Add Account…" affordance per family (tier 4).
- **Rename**: inline, NNW-style; nickname defaults to org name or email local-part.
- **Remove**: forgets the instance (its layout/pins tombstoned), with copy stating nothing is deleted or signed out on disk; re-adding the same account later restores by identity key. Disable (master toggle) remains the reversible half-step, same as providers today.
- **Signed-out/stale instance**: the tile badges an auth error in place (reauth-in-place principle) — it never vanishes and never duplicates. If the home disappears entirely, the instance shows the same "not logged in" state until removed.
- **Menu bar**: pins are per-instance (cap applies per instance); pinned metrics from a second instance carry the instance accent/initial so two Claude pins are tellable apart — design detail to prototype.
- **Local HTTP API**: `/v1/usage/claude` keeps meaning the default instance (no consumer breaks); instances appear additively as `/v1/usage/claude@ab12cd34` and in the collection route.
- **Telemetry**: `provider_id` gains an `account_index`-style dimension or hashed instance suffix — never the email.

### 7.4 Where "Add Account…" lives (grounded in the real UI)

Surface anatomy that constrains placement (all verified in code): the popover is 320pt wide; Customize L1 is a single flat card of provider rows (`grip · icon · name + "N metrics" · toggle · chevron`) with **no sections and no context menus**, plus one `ScreenCrossLinkRow` to Settings below the card; Customize L2 stacks "Always Visible" / "On Demand" metric cards plus `APIKeysSection` for key-managed providers (the only per-provider config-input precedent: caption header + card, collapsed row with status dot + "Add"/"Edit" button, inline editor states); the dashboard's only banner precedent is `DismissableHintCard` (`UpdateBannerCard`, first-run `CustomizeHintCard`) pinned above the provider sections; dashboard provider headers already have a context menu (Hide / Refresh / Customize… / Share Screenshot); Settings is strictly app-level (no provider config lives there — keep it that way). There is currently **no folder picker, no drag-drop, no "+" affordance, and no email string anywhere in the UI** — whatever we add sets the precedent.

Placement is four coordinated affordances with distinct jobs, not one button:

**(a) The suggestion card — the affordance most users actually meet.** Tier-2/3 detections surface as a `DismissableHintCard` on the dashboard: glyph + "Found Another Claude Login" + "work@sunstory.com · Max 20x" + [Add] [✕]. One click, no navigation, no typing — the zero-thinking path, reusing the exact update-banner scaffold. Dismissing tombstones the suggestion (same identity never re-suggested).

```
┌──────────────────────────────────────────┐
│ ◍  Found Another Claude Login        ✕  │
│    work@sunstory.com — Max 20x           │
│                              [ Add ]     │
└──────────────────────────────────────────┘
```

**(b) Customize L1 — the deliberate path.** A quiet "Add Account…" row (plus icon, tertiary) at the bottom of the provider card, mirroring the existing cross-link-row pattern. Global, not per-family — L1 stays a flat reorderable list (instances order anywhere, like any provider), so a per-family "+" has no stable anchor; macOS Internet Accounts proves one global "Add Account" reads instantly. Tapping it: step 1 = provider picker (only multi-home-capable providers listed: Claude, Codex, …); step 2 = folder picker.

```
Customize
┌──────────────────────────────────────────┐
│ ≡  ◍ Claude               [on]  ›        │   ← default instance, unchanged
│ ≡  ◍ Claude — Work        [on]  ›        │   ← instance row, same anatomy
│ ≡  ⬒ Codex                [on]  ›        │
│    …                                     │
│ ─────────────────────────────────────    │
│  ＋ Add Account…                          │   ← new, quiet, last row
└──────────────────────────────────────────┘
```

**(c) The add flow itself — validation as UI.** `NSOpenPanel` (new to the app, but the standard control; presented as a modal panel from the popover) pointed at a folder. On selection, the same strict validator from §7.2 runs and the confirm step *shows what it resolved* — this is where trust is built:

```
┌──────────────────────────────────────────┐
│  ~/.claude-work                           │
│  ✓ Claude Code login found                │
│     work@sunstory.com — Max 20x           │
│     Usage logs: 214 sessions              │
│                     [Cancel] [Add Claude] │
└──────────────────────────────────────────┘
```

A folder that fails validation says exactly why ("No credentials found in this folder — expected `.credentials.json` or a Claude keychain login for this path"), which doubles as the self-serve debugging story. Drag-and-drop of a folder onto the popover can come later; the panel is the v1.

**(d) Per-instance L2 — where the account's own facts live.** Each instance's Customize detail gains an "Account" section above the metric cards (visual sibling of `APIKeysSection`): identity line (email · plan), source line (`~/.claude-work`), inline rename field, and "Remove Account…" (with the "nothing is signed out or deleted on disk" copy). The default instance shows the same section minus Remove. Rename/remove deliberately live here — on the thing itself — not in a management list two levels away.

**Secondary entry, cheap and contextual:** "Add Another Account…" appended to the dashboard provider-header context menu (precedent exists), jumping straight into flow (c) with the provider pre-selected. Power users who right-click the Claude header looking for exactly this will find it.

**Rejected placements:** Settings (app-level surface, confirmed by code and by the deliberate cross-link split); the dashboard header itself (a visible "+" next to every provider name is chrome the 95% single-account majority pays for daily — violates the zero-account-cost rule); the footer Options menu (app-global actions only); a first-class "Accounts manager" screen (a third management surface for a list that is usually length ≤2 — YAGNI, and #987's Accounts section already proved a list-of-accounts UI feels bureaucratic at this scale).

### 7.5 What this deletes from #987

The selection store and projection seam, the process-wide keychain-interaction gate (and its race), keychain enumeration + `showsOngoingUse()` junk heuristics, the "extra Claude accounts have no spend" asymmetry, and the picker UI. What survives: account records (as instances), per-account snapshot keying, discovery-off-the-launch-path, the Codex dir+keychain collapse insight (now: dir → computed keychain lookup), and #962's Desktop machinery as a tier-3 suggestion source.

### 7.6 Phasing

1. **P1 — the model**: instance ids end-to-end (the honest version of what #965 attempted), manual add + strict sibling detection for Claude + Codex, rename/remove/tombstones, per-home spend. Ships the whole promised UX for the two providers that matter.
2. **P2 — reach**: shell-rc hints and switcher-registry adapters as suggestions; Claude Desktop orgs as suggestions; Copilot via `gh` `hosts.yml` `users:` map (the one provider with a native enumerable account list — cheap win).
3. **P3 — "add a login that doesn't exist yet"** (optional, CodexBar-managed-homes precedent): OpenUsage creates `~/.openusage/homes/<name>` and walks the user through the provider's *own* CLI login pointed at it (`CODEX_HOME=… codex login`). No custom OAuth client, no custody — the official client writes the credential; we just chose the folder. Decide after P1 proves the model.

## 8. Open questions for the owner

1. **Metric defaults for extra instances** (the four-defaults rule): copy the provider's template exactly, or start extras with pins **off** to protect the menu bar? (Recommendation: template minus pins.)
2. Naming format: "Claude — Work" nickname-first vs "Claude (rob@sunstory.com)"; is the email subtitle always visible or Customize-only?
3. Per-instance color accents: yes/no, and do they appear in menu-bar pins?
4. Do Claude Desktop org accounts ship in P1 or wait for P2's suggestion tier?
5. Does the instance registry sync via iCloud (paths are machine-specific; identity keys are not — sync identity + nickname, resolve anchor per machine?).
6. Post-first-run tier-2 detections: auto-add (matches today's NewProviderSeeder behavior) or confirm-first (HA rule)? (Recommendation: auto-add only on the first launch that ships the feature; confirm afterwards.)

## 9. Implementation plan (phased — decided 2026-07-16)

The full UX in §7 stands as the destination, but ships in slices. The owner explicitly deferred the add/remove/rename surfaces; Phase 1 is auto-discovery only.

### Phase 1 — auto discovery (now)

Scope, per the owner's spec: **Codex** discovers file (`auth.json` homes) and keychain (`Codex Auth`, per-home hashed account) logins and merges them; **Claude** discovers file (`.credentials.json`), Claude Code keychain (computed per-dir suffixed items), and Cowork/Claude Desktop logins and merges them. Every distinct account becomes an ordinary provider tile named **"Claude 1" / "Claude 2"** (base card takes "1" only when siblings exist). No remove, no rename, no manual add — instances can be **disabled with the existing Customize toggle** (the Known/Enabled machinery already makes that stick). Records remember which ordinal maps to which account (identity key + email label persisted internally).

Mechanics:

- `ProviderInstancesStore` (UserDefaults `openusage.providerInstances.v1`): persisted records `{instanceID, baseProviderID, ordinal, kind, anchorPath, identityKey, identityLabel}`; instance id = `claude@<8-hex sha256(identityKey)>`; reconcile keeps ids/ordinals stable across launches; records are never dropped in P1 (a vanished home shows the provider's normal not-logged-in error).
- Discovery runs synchronously in `AppContainer.init` before the registry is built (no live registration needed), time-budgeted, **zero secret reads**: candidates = `~` dotdirs + `~/.config/*` + the existing Cowork container walk; schema-exact validation (§4.3); identity read from the home (`oauthAccount` / id_token claims); routing = distinct account → record, same account → fold (Cowork dirs partition to their account's card), tool-managed/ephemeral paths → sources only. If the budget expires, persisted instance cards stay hidden for that launch instead of trusting a partial scan.
- Scoped runtimes: `ClaudeAuthStore`/`CodexAuthStore` gain a `scope` (standard byte-identical / config-dir / desktop-only), pinned to exactly one home's file + its *computed* keychain item (no base-service fallback, no env token, no cross-account drift — #987's lesson kept). Scanners scope via injected environment (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`) so per-home spend tiles are real; the Cowork walk is partitioned by account.
- Providers take an injectable `Provider`; descriptor ids derive from `provider.id` (default stays byte-identical `claude.session`; instances get `claude@ab12cd34.session`). `DefaultLayout` translates the base template for instance ids at container init (metrics + expanded copied; **pins deliberately not seeded for instances** — flagged as an owner-confirmable default). `WidgetRegistry.orderedProviderIDs` inserts a new instance right after its base provider in saved orders.
- Enablement: instance ids flow through `NewProviderSeeder` (never-seen + credentials → enabled once; a later manual off is never overridden). `hasLocalCredentials()` for scoped instances is footprint-only (file/keychain-attributes/desktop status) so seeding can never trigger a keychain dialog. Claude's one-time prompt remains refresh-driven; Codex warms a hidden, keyring-only home through one exact post-launch read so its account identity is known before the card can appear.
- Exclusions kept simple in P1: machine-local iCloud history includes account instances and routes them by opaque account identity; the Codex reset-claim service stays bound to the default Codex; pi fold-in stays on default cards; telemetry reports instance ids as-is (hash suffix is pseudonymous).

### Phase 2 — Add Account… (deferred)

The §7.4(b)+(c) affordances: the quiet "Add Account…" row at the bottom of Customize L1, `NSOpenPanel` folder flow, validation-as-UI confirm card showing the resolved identity, plus the provider-header context-menu entry. Also the natural home for shell-rc-hint and switcher-registry **suggestions**.

### Phase 3 — identity & management (deferred)

Rename (inline, NNW-style), remove-with-tombstones ("nothing is signed out"), the dashboard suggestion card (§7.4(a)), email/org subtitles instead of bare ordinals, per-instance accents in menu-bar pins, Claude Desktop org labels. The §7.3 walkthrough and §7.4 mockups describe this end state.

## 10. Sources

Key references: Home Assistant config entries & config-flow docs (developers.home-assistant.io); Monarch/Copilot Money/YNAB help centers on hide-vs-delete and link flows; CodexBar docs (`docs/codex.md`, `docs/claude.md`, `docs/claude-multi-account-and-status-items.md`) and releases; openai/codex source (`auth/storage.rs`, `token_data.rs`, `config_toml.rs`, `protocol.rs`) and issues #26014/#4432/#30684; anthropics/claude-code changelog and issues #24963/#30031/#23906; Anthropic support articles "Log in to your Claude account" and "Use the Claude Agent SDK with your Claude plan"; coverage of the OpenCode block (VentureBeat, The Register, HN 46625918); ccusage environment-variable docs; switcher repos (claude-swap, Symbioose/claude-account-switcher, CCSwitcher, caam, cc-switch). Local forensics: owner's machine, 2026-07-16 (§2).
