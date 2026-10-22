# Codex Accounts Added In OpenUsage

Plan for explicit Codex sign-in inside OpenUsage, modelled on CodexBar's managed accounts. Status:
implemented on `feat/codex-managed-accounts` and verified by the owner on real accounts (Business and
Pro) before it was submitted.

## Goal

Let a user add a second (third, …) ChatGPT/Codex account from inside OpenUsage without touching
their system Codex login, see its Session/Weekly limits and reset credits on its own card, sign that
account in again when its token dies, and remove it. Existing discovery (default home, sibling
homes, xswap, pi, Keychain) keeps working unchanged.

## What CodexBar does (verified in its source, commit `ad0c567`)

- Runs the user's `codex login` with `CODEX_HOME` pointed at a private per-account folder under
  Application Support; the CLI owns the browser flow and writes `auth.json` there.
- Keeps a small registry (`id`, email, workspace, home path, timestamps); the record id is separate
  from the home folder's UUID. Identity is email + workspace, so two users in one workspace stay
  apart and one user with two workspaces gets two rows.
- Validates the login after the CLI exits: reads the new `auth.json`, requires an email, matches the
  identity against existing rows (a matching row keeps its id).
- Reads tokens from managed homes but never refreshes them itself; stale managed logins need a
  manual "Reauth". Display selection never changes the system login; "System Account" promotion is a
  separate, guarded transaction.
- Remove deletes the whole managed home after writing the registry.

## What OpenUsage already has

- Account registry (`ProviderAccountsStore`): stable card ids, identity `workspace|email`, source
  edges, tombstone flag. A new source for a known identity attaches to the existing card.
- Scoped `CodexAuthStore` per card: tries every matching login, rotates tokens in independent file
  homes and writes them back, and discards a result whose login changed mid-refresh.
- Per-card reset-credit claims, per-home local spend attribution, iCloud routing by identity.
- Discovery ran once at launch; adding or removing a login needed a restart (documented then).

## Design

### Storage

- `CodexManagedAccountStore` (`openusage.codexManagedLogins.v1` in UserDefaults): one record per
  managed login — record id (UUID), the home's folder name, verified identity (`workspace|email`),
  created and last-signed-in dates. No tokens, no absolute paths: homes resolve under the current
  root, so a renamed user folder never strands a record. An unreadable list — or one that names a
  folder outside the root — pauses all account management instead of being overwritten.
- Homes live at `~/Library/Application Support/OpenUsage/codex-accounts/<bundle id>/<uuid>/` (mode
  0700; the bundle id keeps a dev build and the release apart). The CLI writes `auth.json` there;
  OpenUsage treats it as an independent writable Codex home, so the existing token rotation and
  write-back apply. Folders no record names (a quit or crash mid-sign-in) are removed at launch.
  The `openusage` command resolves the same root from the app's bundle id.

### Discovery

- Managed homes join the home scan as additional homes. A home whose `auth.json` names an account
  attaches to that account's card through the existing identity merge; a brand-new identity mints a
  new card. The card id never derives from the home path.
- A managed record whose home has no usable login still observes its stored identity, so the card
  stays visible in a signed-out state and "Sign In Again" remains reachable.
- xswap's homes stay read-only; managed homes are never confused with them.

### Sign-in flow

1. Resolve `codex` on the login-shell PATH (Finder launches carry a minimal PATH); fail with a
   friendly "Codex CLI not found" otherwise.
2. Run `codex login -c cli_auth_credentials_store="file"` with `CODEX_HOME=<home>` (the config
   override keeps the login in the private folder instead of the Keychain) in a process group of
   its own (`posix_spawn`), so cancel, timeout, and quit stop the whole group — a shell wrapper
   around the CLI and anything it respawns included; the login is over only when the group is
   empty, and its last output (the CLI's error line) is delivered before the outcome is decided —
   the pipe reader itself reports when it has finished, and the launcher waits for that report. A
   wrapper that detaches the CLI into its own session (`setsid`) is outside that contract and not
   supported. Stream output to show the sign-in URL in case the browser did not open; 15-minute
   timeout.
3. After exit 0, read `<home>/auth.json`, require an access token and a complete identity.
4. Add: identity matching an existing managed record replaces that record's `auth.json` instead of
   creating a duplicate; identity matching an account discovered elsewhere (default home, xswap,
   pi, Keychain) is rejected with a hint — the browser picked the account the user already has.
   Sign In Again: login into a staging folder; the identity must equal the record's, otherwise
   reject and discard the staging folder; on match copy `auth.json` into the record's home (its
   sessions stay).
5. Remove: confirm, delete the managed home (guarded to be a direct child of the managed root, no
   symlinks), drop the record, and evict the card's cached snapshot through the app's live cache so
   a plain card after the rebuild cannot inherit the removed account's numbers. A token refresh
   that was mid-flight writes credentials in place only — it never recreates a removed home, it
   fails instead. Its check-then-write and the publish of a new login hold an advisory lock on the
   home directory (`flock`, shared with the `openusage` CLI, which rotates the same tokens), so a
   stale rotation can never overwrite a fresh Sign In Again on a local volume. Network shares do
   not honor that lock: an SMB share or an NFS mount without locking refuses it, and the write goes
   ahead unlocked with a warning in the log; an NFS mount with locking or a WebDAV share accepts it
   without locking anything, so the write is unlocked there too, without a warning, as every write
   was before this lock existed. External
   logins are never touched. An install that has run in account-card mode stays account-aware:
   once no login with a known account is left (no Codex login at all, or one whose account this
   launch could not read), its plain fallback card names no account, paints no cached snapshot
   (even one a concurrently running `openusage` command wrote back), and takes no synced history
   from a peer Mac either (legacy installs that never had account cards keep behaving as before).
6. Every successful change rebuilds the Codex cards in place: the container runs the Codex half
   of the account pass again (`families: ["codex"]`), swaps that family's runtimes in the provider
   list, and hands the new registry to the layout store (which reloads through the launch path,
   so a new card is seeded like a launch and a removed card's widgets go), the data store (which
   drops the snapshot of a removed card and of a card that kept its id but changed hands — the
   bare `codex` card after the last Remove — paints a new card from its own cache only, renames a
   retained snapshot after its card without counting that as a fetch, and lets a fetch that
   outlived its runtime — or its card — neither publish nor hold the shared spinner; the rebuilt
   cards are then fetched at once, each in its own forced refresh, without the section waiting for
   the network), the reset-claim
   services, and `NewProviderSeeder` (which turns a never-seen card on once its login is found,
   never when every installed card of the family is off — judged when the card is turned on, not
   when its probe began, since the probe can wait on a Keychain prompt — and never for a card the
   user toggled while the probe ran). The service
   shows "Updating the Codex cards…" meanwhile; the Customize screen confirms through its notice
   pill (observed there, since removing the open card pops its section first). A
   launch whose login shell was unreadable has no Codex cards to rebuild (Add is refused there),
   so its reload is skipped and the launch state stays. Quitting kills a
   running sign-in, and a sign-in that is only just starting as the app quits is refused instead
   of being left behind (spawn and quit share one lock). Cancel is re-checked on the main actor
   before anything is published, so a cancel that lands while the login's result is being read
   publishes nothing. Known limitation: on a Finder launch whose login-shell capture failed and
   that has no shell snapshot yet, Codex discovery (managed homes included) is skipped until the
   next launch, as for every other Codex source; Add Account refuses in that launch (the other
   logins are unknown, so a duplicate could not be told apart) and asks for a relaunch, which only
   helps once the shell profile loads within the capture's five seconds.

### UI

- Customize → any Codex card → new **Codex Accounts** section: one row per managed login (the
  email, the sign-in date, and the workspace only when another row shares the email) with
  **Sign In Again** and **Remove…** behind the row's menu, **Add Account…** at the bottom, inline
  progress with **Open Sign-In Page** / **Copy Link**, the CLI's own error line on failure (shown
  in the section, never written to the log), and the Customize notice pill on success. Cards are named `Codex: <email>` (an xswap alias or pi
  label still wins; the workspace is added only when two cards share an email), and a lone card
  is plain `Codex`, as a lone Claude card is `Claude`. Sentence-case copy, no tooltips.

### Out of scope

- Switching the system `~/.codex` login from OpenUsage.
- Reattributing old shared session logs to accounts.

## Verification

- `swift build`, `swift test` (new suites: store round-trip, assembly with managed records,
  login service with a fake process, the live rebuild of the Codex cards).
- `script/build_and_run.sh`, then on real accounts: add a second account, confirm two cards with
  independent limits appear without a relaunch, claim a reset on the new card, kill its token and
  use Sign In Again, remove it, and confirm the card is gone while the default login card is
  unchanged.
