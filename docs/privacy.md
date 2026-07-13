# Privacy & Usage Data

OpenUsage can share **anonymous** usage data to help us understand how the app is used and catch problems. It is on by default and you can turn it off any time in **Settings → Privacy → Share Anonymous Usage**.

## What is shared

When sharing is on, OpenUsage sends two kinds of small daily summaries: one app-use event per day and,
for each provider refreshed that day, at most one provider-refresh event:

- **App use** — that the app was active today, the app and macOS version, which providers and metrics you have enabled, and which metrics you've pinned to the menu bar or tucked behind the "show more" caret. A random ID (not tied to you or any account) lets us count daily active users without identifying anyone.
- **Provider refreshes** — per provider, how many refreshes succeeded or failed that day, the **kinds** of errors that happened (for example "not logged in", "network", or an HTTP status group), and how many manual refreshes you triggered.

It also reports **crashes**, so we can find and fix the bugs that make the app quit unexpectedly:

- **Crash reports** — if OpenUsage crashes, it saves a report and sends it the next time you open the app: the technical stack trace (which parts of *OpenUsage's own code* were running when it crashed) plus the app and macOS version. This contains no account details, credentials, or usage values — just where in the app the crash happened.

## What is never shared

- No account details, names, emails, or credentials.
- No actual usage **values** (no spend amounts, token counts, or limits).
- No error **messages** or file paths — only coarse error categories as counts.
- Nothing while the toggle is off.

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

Besides the provider API calls the vendor's own tools would make, OpenUsage fetches public [model price lists](pricing.md) about once an hour (from `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages). These are plain downloads of public data — they carry no usage, log, or account information, and they run regardless of the Share Anonymous Usage setting. The spend tiles are computed from local CLI logs entirely on your Mac; no log data ever leaves it.

If you explicitly turn on [iCloud Sync](icloud-sync.md), OpenUsage writes normalized daily tokens,
spend, and model totals to its private iCloud container so your own Macs can show one combined summary.
Credentials, account limits, provider responses, and raw logs are never written there. This is separate
from anonymous usage sharing: iCloud Sync defaults off and uses your iCloud account, while the analytics
toggle controls PostHog events.

## How it works

- Data is fully anonymous: OpenUsage never identifies you to the analytics service and creates no user profile.
- Crash reports use the **same** Share Anonymous Usage switch — turn it off and crash reporting is off too, with no separate setting to find. While it's off, no crash report is recorded or sent.
- Counts are rolled up locally and sent as daily summaries, so the app's normal 5-minute refresh never turns into a flood of network calls.
- Your choice and the anonymous ID are stored separately from the rest of the app's settings, so settings migrations and updates do not re-enable sharing or change your ID.

## Turning it off

Open **Settings → Privacy** and switch **Share Anonymous Usage** off. Sharing stops immediately and nothing further is sent.
