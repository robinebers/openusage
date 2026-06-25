# Privacy & Usage Data

OpenUsage can share **anonymous** usage data to help us understand how the app is used and catch problems. It is on by default and you can turn it off any time in **Settings → Privacy → Share Anonymous Usage**.

## What is shared

When sharing is on, OpenUsage sends two small summaries, **at most once a day each**:

- **App use** — that the app was active today, the app and macOS version, which providers and metrics you have enabled, and which metrics you've pinned to the menu bar or tucked behind the "show more" caret. A random ID (not tied to you or any account) lets us count daily active users without identifying anyone.
- **Provider refreshes** — per provider, how many refreshes succeeded or failed that day, the **kinds** of errors that happened (for example "not logged in", "network", or an HTTP status group), and how many manual refreshes you triggered.

It also reports **crashes**, so we can find and fix the bugs that make the app quit unexpectedly:

- **Crash reports** — if OpenUsage crashes, it saves a report and sends it the next time you open the app: the technical stack trace (which parts of *OpenUsage's own code* were running when it crashed) plus the app and macOS version. This contains no account details, credentials, or usage values — just where in the app the crash happened.

## What is never shared

- No account details, names, emails, or credentials.
- No actual usage **values** (no spend amounts, token counts, or limits).
- No error **messages** or file paths — only coarse error categories as counts.
- Nothing while the toggle is off.

## How it works

- Data is fully anonymous: OpenUsage never identifies you to the analytics service and creates no user profile.
- Crash reports use the **same** Share Anonymous Usage switch — turn it off and crash reporting is off too, with no separate setting to find. While it's off, no crash report is recorded or sent.
- Counts are rolled up locally and sent as a daily summary, so the app's normal 5-minute refresh never turns into a flood of network calls.
- Your choice and the anonymous ID are stored separately from the rest of the app's settings, so a beta update (which resets other settings) does not re-enable sharing or change your ID.

## Turning it off

Open **Settings → Privacy** and switch **Share Anonymous Usage** off. Sharing stops immediately and nothing further is sent.
