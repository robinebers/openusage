# Privacy & Usage Data

OpenUsage always sends an **anonymous daily active ping** and **anonymous crash reports** so we can
count active users and fix app crashes. These are not optional.

You can also share extra anonymous usage analytics to help us understand how the app is used and catch
problems. Extra analytics is on by default for new installs. Turn it off any time in
**Settings → Privacy → Help make OpenUsage better by sharing anonymous usage analytics**. Existing
installs keep the choice they already stored.

## What is always shared

Once per local day, OpenUsage sends an anonymous **app use** ping: that the app was active today, the
app and macOS version, which providers and metrics you have enabled, and which metrics you've pinned
to the menu bar or tucked behind the "show more" caret. A random ID (not tied to you or any account)
lets us count daily active users without identifying anyone.

- **Crash reports** — if OpenUsage crashes, it saves a report and sends it the next time you open the
  app: the technical stack trace (which parts of *OpenUsage's own code* were running when it crashed)
  plus the app and macOS version. This contains no account details, credentials, or usage values —
  just where in the app the crash happened.

## What the toggle shares

When extra analytics are on, OpenUsage also sends, for each provider refreshed that day, at most one
provider-refresh event:

- **Provider refreshes** — per provider, how many refreshes succeeded or failed that day, the **kinds**
  of errors that happened (for example "not logged in", "network", or an HTTP status group), and how
  many manual refreshes you triggered.

Turning the toggle off stops these extra events. Daily activity and crash reports continue.

## What is never shared

- No account details, names, emails, or credentials.
- No actual usage **values** (no spend amounts, token counts, or limits).
- No error **messages** or file paths — only coarse error categories as counts.

## Credentials stored on this Mac

OpenUsage primarily reads credentials that provider tools already keep on your Mac. When it writes a
user-supplied API key or saves a refreshed credential, the file is replaced atomically and restricted to
your macOS account (owner read and write only). Antigravity's short-lived refreshed-token cache is tied
to the current Keychain login using a one-way fingerprint; the refresh credential itself is not copied.
The cache is never used after logout, an account change, or while Keychain access is unavailable.

Claude Desktop access is strictly read-only. OpenUsage may ask macOS for permission to use the
`Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token. It never uses
Desktop's rotating refresh token and never modifies Desktop's config, cookies, or Keychain data.

## Other network requests

Besides the provider API calls the vendor's own tools would make, OpenUsage fetches public [model price lists](pricing.md) about once an hour (from `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages). These are plain downloads of public data — they carry no usage, log, or account information, and they run regardless of the analytics toggle. The spend tiles are computed from local CLI logs entirely on your Mac; no log data ever leaves it.

To avoid re-reading unchanged Claude, Codex, and pi logs after every relaunch, OpenUsage keeps their
parsed usage events in `~/Library/Application Support/OpenUsage/log-scan-cache/`. These records contain
the usage metadata needed for local totals, including any per-event cost already recorded by a provider,
but not raw JSONL lines or conversation text. They are private to your macOS account and are never sent
to PostHog, a provider, or iCloud. Old source-file records are dropped as the scan window advances, and
identity caches that have not been used for 35 days are removed. OpenUsage's pricing engine runs after
the cache is read, so its computed aggregates and totals are not persisted in this cache.

If you explicitly turn on [iCloud Sync](icloud-sync.md), OpenUsage writes normalized daily tokens,
spend, and model totals to its private iCloud container so your own Macs can show one combined summary.
Credentials, account limits, provider responses, and raw logs are never written there. This is separate
from anonymous usage analytics: iCloud Sync defaults off and uses your iCloud account, while the
analytics toggle controls extra PostHog events, not daily activity or crash reports.

## How it works

- Data is fully anonymous: OpenUsage never identifies you to the analytics service and creates no user profile.
- Daily activity and crash reports are always enabled, regardless of the extra-analytics switch.
- Counts are rolled up locally and sent as daily summaries, so the app's normal 5-minute refresh never turns into a flood of network calls.
- Your analytics choice and the anonymous ID are stored separately from the rest of the app's settings, so settings migrations and updates do not re-enable extra analytics or change your ID.

## Turning extra analytics off

Open **Settings → Privacy** and switch **Help make OpenUsage better by sharing anonymous usage analytics**
off. Extra usage analytics stop. Daily activity and crash reports continue.
