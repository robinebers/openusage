# Providers

How each provider signs in and what its card shows.

- Every value comes from the provider's API. The one estimate is ChatGPT's credits, at 4¢ each.
- OpenUsage computes no spend from logs and applies no model pricing. A metric the provider does not
  report stays hidden.
- Time ranges (Today, Yesterday, This Week, and the like) always show, at 0 when the provider
  reports nothing.
- Balances show even at `$0 left`.
- Extra Usage shows while the provider has it on, even at `$0`, and hides while it is off.

| Provider | Sign-in | Card shows |
|---|---|---|
| Claude | Browser (claude.ai OAuth) | Session, Weekly, Sonnet, Fable, Extra Usage, Rate Limit Resets |
| ChatGPT | Browser (OpenAI OAuth), with a device-code fallback | Session, Weekly, Spark, Spark Weekly, Extra Usage, Credit Limit, Rate Limit Resets, Today, Yesterday, Last 30 Days |
| Cursor | Browser (cursor.com) | Total Usage, Cursor Models, Other Models, Extra Usage, Grok Bot, Requests, Credits, Today, Yesterday, Last 30 Days |
| Antigravity | Browser (Google OAuth) | Gemini 5h, Gemini, Argon, Claude 5h, Claude |
| Copilot | Device code (GitHub or GHE.com) | Credits, Extra Usage, Chat, Completions |
| Copilot organization | Organization and token | Org Credits, Org Spend |
| Devin | Browser (Windsurf), then a pasted token | Daily, Weekly, Extra Usage |
| Grok | Device code (xAI) | Weekly, Extra Usage |
| Muse Code | Device code (Meta) | Session, Weekly |
| Ollama | API key | Session, Weekly, Monthly, Extra Usage, Today, Yesterday, Last 30 Days, Requests |
| OpenCode | API key | Session, Weekly, Monthly |
| OpenRouter | Management API key, or a standard API key | Balance, Today, Yesterday, This Week, This Month, Prior 30 Days, Key Limit, Budget, Free Requests |
| Z.ai | API key | Session, Weekly, Web Searches, Rate Limit Resets |

## What you grant

Each OAuth sign-in asks for the least the card needs. A refresh never asks for more than the sign-in
did. The token is stored in the app's Keychain.

| Provider | Scopes requested | Notes |
|---|---|---|
| Claude | `user:profile` | The token cannot run inference, create API keys, or reach Claude Code sessions, MCP servers, or uploads. |
| ChatGPT | `openid profile email offline_access` | Plain OpenID Connect. The email names the account. |
| Cursor | none | Cursor's sign-in returns a dashboard session with no scopes. |
| Antigravity | `cloud-platform`, `userinfo.email` | Google's quota API requires `cloud-platform`. |
| Copilot | `read:user` (ignored by GitHub) | GitHub ignores the scopes a GitHub App asks for, so OpenUsage cannot narrow the token. It reads only your login and your quota with it. |
| Copilot organization | none; you create the token | A fine-grained personal access token with Organization permissions, Administration, Read-only, from an organization owner or billing manager. |
| Devin | `openid profile email` | OpenUsage trades the token for the account's API key, the same key Windsurf's editor plugins use. |
| Grok | `openid email offline_access grok-cli:access` | OpenUsage doesn't ask for `api:access`, which would let the token run Grok models. |
| Muse Code | none | Meta's device sign-in takes no scopes. The usage read also returns the account's Model API key, which OpenUsage never reads or stores. |

A narrower grant applies the next time you add an account. To get it for an existing account, remove
the account and add it again. Claude is the exception: a refreshed Claude token carries only
`user:profile`.

Spending a Claude reset with a `user:profile`-only sign-in is untested. If Anthropic refuses it, the
resets popover says so, and you can spend the reset in Claude Code instead.

## Claude

- Sign in through claude.ai in your browser. If the browser shows a code instead of returning to the
  app, paste it into the sheet.
- The card reads the plan (Pro, Max, or Ultra) once an hour. Ultra has no 5-hour limit, so it has no
  Session row.
- Extra Usage shows spend against the monthly limit, or the amount spent when there is no limit, in
  the account's billing currency. It hides while extra usage is off. On an Enterprise plan, where
  this is the whole monthly bill, the row reads Spend.
- **Limit Resets** counts the account's rate-limit resets. Click the count to see when each expires.
  Choose **Use**, then **Reset**, to spend one.

## ChatGPT

- Sign in through OpenAI in your browser. If the app cannot listen on port 1455, it offers a device
  code instead.
- The command line calls this provider `codex`.
- Extra Usage shows your credits in dollars, at 4¢ a credit, even at `$0`. It hides while ChatGPT
  reports credits off.
- Rate-limit resets work like Claude's.
- Credit Limit shows the credits a workspace lets you spend and when that resets. It shows only when
  the workspace sets one.

Today, Yesterday, and Last 30 Days show the text tokens ChatGPT counted per UTC day, from the
reports behind the Codex app's Analytics view. ChatGPT reports no dollar amount for them.

The card reads these reports once an hour, at the start of a UTC day, and on ⌘R. If today's or
yesterday's counts can't be read, that range reads 0, and Last 30 Days still includes the older
days.

## Cursor

- Sign in through cursor.com in your browser.
- Extra Usage is on-demand usage and resets with the billing cycle. It hides when on-demand usage is
  off (no spend limit, or a $0 one). When the limit is the team's shared pool and not yours, the row
  reads Team Spend.
- Credits reads `$0 left` when Cursor reports none.

Today, Yesterday, and Last 30 Days show what Cursor charged and the tokens it reported, from the
usage history on Cursor's Usage page. The charge counts only on-demand usage. Included usage and
errored or free requests count as $0. Tokens count every event.

How the history is read:

- One local day at a time, at most 4 days at once and for at most 20 seconds per refresh.
- Today and yesterday on every refresh. An older day until one read of it succeeds.
- Days are kept in memory, so the first refresh after a launch reads all 30 days again.
- A failed day adds nothing to a range.
- If Cursor rate-limits a read, the retry waits for its Retry-After, or an hour.

## Antigravity

- Sign in with Google in your browser.
- The card shows the Gemini and Claude pools (5-hour and weekly) and the Argon weekly window.
- If the project has no quota subscription, the card explains the access issue. If the project
  lookup failed, refresh again.

## Copilot

- Sign in with a GitHub device code. The sign-in first asks for a domain: leave it blank for
  github.com, or enter your company's GitHub Enterprise address on GHE.com, such as
  `octocorp.ghe.com`. A pasted link works, and a bare name like `octocorp` means
  `octocorp.ghe.com`. Self-hosted GitHub Enterprise Server isn't supported.
- A GHE.com sign-in checks your Copilot seat once and isn't added without one. The account shows its
  domain on the dashboard and **Signed in at** its domain on its page. **Sign In Again…** keeps the
  domain.
- Extra Usage hides when the plan doesn't allow it.

To see an organization's billing, add it as its own account. Choose Copilot, then **Organization
Billing**, and enter the organization and a token from an owner or billing manager. The card shows
**Org Credits** (AI credits the organization used this month) and **Org Spend** (dollars billed
beyond the included pool).

## Devin

- Sign in on windsurf.com in your browser, then paste the token the page shows. The page mentions VS
  Code, but the token works here too.
- Extra Usage shows the balance whenever Windsurf reports one, even `$0 left`. Windsurf leaves out a
  zero balance, and then the row hides.
- A plan that hides its daily quota shows it in the Weekly row when the plan has no weekly quota.
- An account with no quota and no balance has nothing to show, and the card says so.

## Grok

- Sign in with an xAI device code.
- Weekly is the shared pool. Extra Usage shows the pay-as-you-go cap and hides when there is no cap
  or a $0 one.
- A team account has no personal quota. Its card shows the plan and says so.

## Muse Code

- Sign in with a Meta device code. The browser opens with the code filled in. The account takes the
  email Muse reports.
- The card shows the Muse Code plan, the 5-hour Session, and the Weekly limit.
- Muse reports no usage until the plan's first prompt, so both limits read 0% until then.
- Muse leaves out usage while the 5-hour window is idle, so the card keeps the last values it read.
  A window whose reset has passed reads 0%.
- A Meta account without a Muse Code subscription has no quota, and the card says so.
- The sign-in has no renewal. When Meta stops accepting it, use **Sign In Again…**.

## Ollama

- Paste an API key from [ollama.com/settings/keys](https://ollama.com/settings/keys).
- The card shows the session, weekly, and monthly windows your plan has.
- Extra Usage shows purchased credits whenever Ollama reports them, even `$0 left`.
- The right-click menu adds an **API Keys** link.

Today, Yesterday, and Last 30 Days show Ollama's usage per UTC day: its dollar value (what the
requests are worth, whether the plan or credits paid) and the input and output tokens. Requests
counts the last 30 days. A legacy plan reports only requests, so its card shows Requests alone.

The card reads all 30 days after a launch, then today and yesterday once an hour, at the start of a
UTC day, and on ⌘R.

## OpenCode

- Paste an API key from the [OpenCode console](https://opencode.ai/console).
- The card shows the session, weekly, and monthly caps, and the plan (Go).

## OpenRouter

Paste a **Management** key from
[openrouter.ai/settings/management-keys](https://openrouter.ai/settings/management-keys) to see the
whole account.

- **Balance** is the credits you bought minus what you spent. It has no bar.
- Today, This Week, and This Month add up the spend of every standard key in your default workspace,
  disabled and expired keys included.
- Yesterday and Prior 30 Days come from OpenRouter's activity, which covers the 30 UTC days before
  today. The card reads all 30 days after a launch, then yesterday once an hour.
- A Management key scoped to one workspace has no Balance, and its ranges add up that workspace's
  keys.
- Spend through your own provider keys (BYOK) never counts toward the credit spend.

A standard API key shows its own spend: Today, This Week, This Month, **Key Limit** when the key has
a limit, **Budget** when a guardrail or workspace budget applies, and **Free Requests** for the UTC
day. It has no Balance, and its Yesterday and Prior 30 Days read $0. A daily, weekly, or monthly
limit resets at midnight UTC, and weeks start on Monday.

The right-click menu adds a **Credits** link.

## Z.ai

- Paste an API key from the [Z.ai key list](https://z.ai/manage-apikey/apikey-list).
- The card shows the GLM Coding Plan session and weekly windows and the web-search quota.
- A key without a GLM Coding Plan has no quota, and the card says so.
- **Limit Resets** counts the banked Session and Weekly resets. Click the count to see them by window.
  **Use** spends the earliest of a window.
- The right-click menu adds an **API Keys** link.

## Errors

A warning icon next to an account means the last refresh failed, or the provider has no usage to
report. The account's right-click menu starts with the reason.

- **Sign-in expired.** Use **Sign In Again…** on the account's page.
- **Rejected the API key.** Use **Replace API Key…** on the account's page.
- **Rate limited** and HTTP errors clear on a later refresh. See [Refreshing](refreshing.md).
- Accounts from a CLIProxyAPI hub have their own messages. See
  [CLIProxyAPI hubs](cliproxyapi.md#when-something-goes-wrong).
