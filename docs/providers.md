# Providers

How each provider signs in and what its card shows. Every value comes from the provider's own API,
except ChatGPT's credit value, an estimate at 4¢ a credit.
OpenUsage computes no spend from logs and applies no model pricing; a metric the provider does not
report stays hidden.

| Provider | Sign-in | Card shows |
|---|---|---|
| Claude | Browser (claude.ai OAuth) | Session, Weekly, Sonnet, Fable, Extra Usage, Rate Limit Resets |
| ChatGPT | Browser (OpenAI OAuth), with a device-code fallback | Session, Weekly, Spark, Spark Weekly, Extra Usage, Credit Limit, Rate Limit Resets, Today, Yesterday, Last 30 Days |
| Cursor | Browser (cursor.com) | Total Usage, Cursor Models, Other Models, Extra Usage, Grok Bot, Requests, Credits |
| Antigravity | Browser (Google OAuth) | Gemini 5h, Gemini, Argon, Claude 5h, Claude |
| Copilot | Device code (GitHub) | Credits, Extra Usage, Chat, Completions |
| Copilot organization | Organization and token | Org Credits, Org Spend |
| Devin | Browser (Windsurf), then a pasted token | Daily, Weekly, Extra Usage |
| Grok | Device code (xAI) | Weekly, Extra Usage |
| Ollama | API key | Session, Weekly, Monthly, Extra Usage |
| OpenCode | API key | Session, Weekly, Monthly |
| OpenRouter | Management API key, or a standard API key | Credits, Balance, Today, Yesterday, This Week, This Month, Prior 30 Days, Requests, Key Limit, Budget, Free Requests |
| Z.ai | API key | Session, Weekly, Web Searches |

## What you grant

Each OAuth sign-in asks the provider for the least the card's reads need, and a refresh never asks for
more than the sign-in did. The token sits in the app's Keychain, so what it can do is what you grant
here.

| Provider | Scopes requested | Why |
|---|---|---|
| Claude | `user:profile` | `/api/oauth/usage` and `/api/oauth/profile` require it and nothing else. The token cannot run inference, create API keys, or reach Claude Code sessions, MCP servers, or uploads. |
| ChatGPT | `openid profile email offline_access` | Plain OpenID Connect: the email names the account and `offline_access` is the refresh token. The usage endpoint reads the account id from the token itself. |
| Cursor | none (Cursor's own sign-in, no scopes) | Cursor's login returns a dashboard session; there is no scope to narrow. |
| Antigravity | `cloud-platform`, `userinfo.email` | Cloud Code's quota API is a Google Cloud API and takes `cloud-platform`; the email names the account. Every Cloud Code client, Gemini CLI included, asks for `cloud-platform`; none is known to work without it. The Antigravity app also asks for `userinfo.profile`, `cclog`, and `experimentsandconfigs`; the card never uses them. |
| Copilot | `read:user` (ignored by GitHub) | The scope Copilot's own sign-in asks for. Copilot's sign-in is a GitHub App, and GitHub ignores the scopes a GitHub App asks for, so the token can reach whatever GitHub grants its Copilot app, within what your GitHub account can do. That is more than your profile, and OpenUsage cannot narrow it. OpenUsage uses the token only to read your login from `/user` at sign-in and your quota from `/copilot_internal/user`. |
| Copilot organization | none requested; you create the token | A fine-grained personal access token with Organization permissions → Administration → Read-only, from an organization owner or billing manager. OpenUsage uses it only to read the organization's AI-credit usage, once per refresh. |
| Devin | `openid profile email` | What Windsurf's editor plugins send. OpenUsage trades the pasted token for the account's API key, the same key those plugins use, and Windsurf offers no narrower key. OpenUsage sends the key only to Windsurf's `GetUserStatus`, once per refresh. |
| Grok | `openid email offline_access grok-cli:access` | `grok-cli:access` lets the token read the Grok CLI proxy, where the settings and billing reads go, and the email names the account. The Grok CLI also asks for `profile` and `api:access`, which lets its token run Grok models through `api.x.ai`; the card uses neither, so it doesn't ask for them. |

A narrower grant applies the next time you add an account. An account you added before keeps its
token and keeps working; remove it and add it again if you want the smaller grant now. Claude is the
exception: its refresh asks for `user:profile` only, so a refreshed Claude access token carries only
that whatever the original sign-in granted.

Spending a Claude reset has not been tried with a `user:profile`-only sign-in; every other client that
spends one uses Claude Code's wider grant. If Anthropic refuses the claim for that reason, the resets
popover says this sign-in can't use resets, and you can spend the reset in Claude Code instead.

## Claude

Sign in through claude.ai in your browser. The sheet also accepts a pasted code if your browser shows
one instead of returning to the app. The card reads `/api/oauth/usage` for the session, weekly,
Sonnet, and Fable windows and the extra-usage spend, and `/api/oauth/profile` once an hour for the
plan, such as Pro, Max, or Ultra. A verified Ultra account has no 5-hour limit, so its card has no
Session row. Extra Usage is a bar against the monthly limit, or reads like `$12.34 spent` when the
account sets none.

The **Limit Resets** row counts the account's available rate-limit resets. Click the count to see
when each expires. Choose **Use**, then **Reset** to spend one.

## ChatGPT

Sign in through OpenAI in your browser. The account shows as ChatGPT; its provider id, as the command line
takes it, is `codex`. When the app cannot listen on port 1455 for the browser's
return, it offers a device code instead. The card reads `/backend-api/wham/usage` for the session and weekly windows, the Spark
windows, and extra-usage credits, and the plan (Plus, Pro, Team, Business). The Extra Usage row shows
the dollar value of the credits you have, an estimate at 4¢ a credit, and hides when you have none. Rate-limit reset credits work like Claude's
Limit Resets row. Credit Limit shows the credits a workspace lets the member spend and when that resets;
it shows only when the workspace sets one.

Today, Yesterday, and Last 30 Days show the text tokens ChatGPT counted on UTC days, from the reports the
Codex app's Analytics view reads. A range adds up the days that report tokens. Open a range to see
the token breakdown and each named model's share of reported credits or turns. ChatGPT reports no
dollar amount for these ranges.

The card reads the reports once an hour, on the first refresh of a new UTC day, and on ⌘R. Each
report has its own cache and retry schedule. If the credit report is unavailable, the token counts
still show. If today's or yesterday's counts cannot be read, Last 30 Days still includes the older
days already read.

## Cursor

Sign in through cursor.com in your browser. The card reads Cursor's dashboard API for Total Usage,
Cursor Models (auto), Other Models (API), on-demand Extra Usage, Grok Bot, Requests, and Credits, and
the plan. Extra Usage resets with the billing cycle, like Total Usage. Cursor stores the sign-in's expiry and renews it before then.

Cursor's plan endpoint says Pro for some Enterprise and Team seats. Once an hour, together with the
plan, the card reads Cursor's `usage-summary`, which names the seat's membership. A seat whose
membership is Enterprise or Team shows that name where the plan endpoint says Pro or nothing. Any other
plan name, such as Ultra, stays. When the seat's usage read has no Extra Usage, the card takes Extra
Usage from `usage-summary` and reads it on every refresh.

Today, Yesterday, and Last 30 Days show what Cursor charged the account and the tokens it reported.
The charge is the sum of `chargedCents` on the account's on-demand usage events
(`USAGE_EVENT_KIND_USAGE_BASED`) in Cursor's usage history, the list on Cursor's Usage page. Usage the
plan includes, and errored or free requests, count as $0. Tokens are the input, output, cache read, and
cache write tokens of every event, whatever its kind; an event that reports no token usage counts as
zero tokens.
Rest the pointer on a Today, Yesterday, or Last 30 Days figure to see what Cursor reported for that range:
the charge, each kind of token, and the top five models, the rest as Other.
The card reads the history one local day at a time, at most 4 days at once and for at most 20 seconds per
refresh. Today and yesterday are read on every refresh; an older day is read until one read of it
succeeds. The days are kept in memory for each account, so the first refresh after a launch reads all
30 days again. Last 30 Days sums the days read so far, even if today or yesterday could not be read.
A failed day stays out of the sum, and the range details note the gap. If Cursor rate-limits a
history read, retries wait for its Retry-After or an hour when it gives no time.


## Antigravity

Sign in with Google in your browser. The card reads the Cloud Code quota API for the Gemini and Claude
pools (5-hour and weekly windows) and the Argon weekly window, and shows the plan under the name
Google sells it as (Google AI Pro, Google AI Ultra, Google AI Ultra Lite) or the tier's own name.
If Google reports that the project has no quota subscription, the card explains the access issue.
If the project lookup failed, try refreshing again.

## Copilot

Sign in with a GitHub device code. The card reads `/copilot_internal/user` for premium credits,
extra-usage spend, and the chat and completion counts, and the plan.

To see an organization's billing, add it as its own account: choose Copilot, then **Organization
Billing**, and enter the organization and a token from an owner or billing manager. The card reads
the organization's AI-credit usage report on every refresh for **Org Credits** (AI credits the whole
organization used this month) and **Org Spend** (dollars billed beyond the included pool). This read
has not yet been tried against a real organization token.

## Devin

Sign in on windsurf.com in your browser, then paste the token the page shows. Its instructions name
VS Code, but the token works the same here. OpenUsage trades the token for the account's API key with
Windsurf's `RegisterUser` and reads `GetUserStatus` on every refresh for the daily and weekly quotas,
the extra-usage balance, and the plan. A plan that hides its daily quota shows it in the Weekly row when
the plan has no weekly quota. An account with neither quota nor a balance has nothing to show, and the
card says so.


## Grok

Sign in with an xAI device code. The card reads the Grok settings and billing endpoints for the weekly
shared pool, pay-as-you-go extra usage, and the plan. A team account has no personal quota to read.
Its card shows the plan and says so, with no rows.

## Ollama

Paste an API key from [ollama.com/settings/keys](https://ollama.com/settings/keys). The card reads the
balance API for the session, weekly, and monthly windows that your plan has, plus purchased credits,
and the plan. A new account is named after the email ollama.com reports for the key, or "Ollama" if
it reports none. The card's right-click menu adds an **API Keys** link to
[ollama.com/settings/keys](https://ollama.com/settings/keys).

Today, Yesterday, and Last 30 Days show what Ollama's `/api/usage` reports for each UTC day: the usage
value in dollars (`usage_usd`, what the requests are worth, whether the plan or purchased credits paid
for them) and the tokens, input plus output. Cached input is already part of input. Requests counts the
last 30 days' requests. A legacy plan reports only requests, so its card shows Requests alone. Rest the
pointer on a Today, Yesterday, or Last 30 Days figure to see what Ollama reported for that range: the
usage value, each kind of token, and the top five models, the rest as Other. When Ollama reports
usage beyond the ten models it names for a day, that day contributes to the range totals only.
Other days can still contribute to the model ranking.
The card reads all 30 days once after a launch, then today and yesterday from the last 7 days once an
hour, at the start of a new UTC day, and on ⌘R. If a read fails, the range can still show figures
from the other days already read.

## OpenCode

Paste an API key from the [OpenCode console](https://opencode.ai/console). The card reads
`/zen/go/v1/usage` for the session, weekly, and monthly caps, and shows the plan (Go).

## OpenRouter

Paste a **Management** key from
[openrouter.ai/settings/management-keys](https://openrouter.ai/settings/management-keys) to see the
whole account. The card reads `/api/v1/credits` for **Credits** (what you spent of the credits you
bought) and **Balance**. Today, This Week, and This Month add up the spend of every standard API key in
your default workspace, disabled and expired keys included, from `/api/v1/keys`. Keys in other
workspaces don't count. A Management key scoped to one workspace can't read the account's credits, so
its card has no Credits or Balance, and its Today, This Week, and This Month add up that workspace's
keys.

Today, This Week, and This Month show the credit spend first, then what the keys spent through your
own provider keys (BYOK), which is never added to it. A Management key also reads `/api/v1/activity`,
which covers the 30 UTC days before today: **Yesterday** and **Prior 30 Days** show the spend and the
tokens (prompt plus completion), and **Requests** counts the requests of those 30 days. The card reads
all 30 days after a launch, yesterday again once an hour, and a new UTC day right after midnight.
If the activity read fails, Prior 30 Days can still show older days already read. The spend totals
from the keys endpoint remain available.

Rest the pointer on a Today, Yesterday, This Week, This Month, or Prior 30 Days figure to see what
OpenRouter reported for that range. For Today, This Week, and This Month that is the spend and BYOK. For
Yesterday and Prior 30 Days it adds the prompt, cached, completion, and reasoning tokens, and the top
five models, the rest as Other. Prompt tokens include the cached ones, and
completion tokens include the reasoning ones.

A standard API key shows its own spend from `/api/v1/key`: Today, This Week, This Month, **Key Limit**
when the key has a credit limit, **Budget** when a guardrail or workspace budget applies to it, and
**Free Requests**, the account's free-model requests for the UTC day. A daily, weekly, or monthly limit
resets at midnight UTC, and weeks start on Monday. OpenRouter lets only a Management key read the
credits and the activity, so a standard key's card has no Credits, Balance, Yesterday, Prior 30 Days, or
Requests.

The card's right-click menu adds a **Credits** link to
[openrouter.ai/settings/credits](https://openrouter.ai/settings/credits).

## Z.ai

Paste an API key from the [Z.ai key list](https://z.ai/manage-apikey/apikey-list). The card reads the
GLM Coding Plan subscription and quota endpoints for the session and weekly windows, the web-search
quota, and the plan. A key with no GLM Coding Plan has no quota to read, and the card says so. The
card's right-click menu adds an **API Keys** link to the
[Z.ai key list](https://z.ai/manage-apikey/apikey-list).

## Errors

A warning icon next to the account's name means the last refresh failed, or that the provider has no
usage to report, as for a Grok team account; the account's right-click menu starts with the reason.
"Sign-in expired" means the provider rejected the stored sign-in: remove the account and add it
again. "Rejected the API key" means the key no longer works: use **Replace API Key…** on the account's
page. "Rate limited" and HTTP errors clear on a later refresh. See
[Refreshing](refreshing.md). An account from a CLIProxyAPI hub has its own messages, which point to
the hub; see [CLIProxyAPI hubs](cliproxyapi.md#when-something-goes-wrong).
