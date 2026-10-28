# Providers

How each provider signs in and what its card shows. Every value comes from the provider's own API.
OpenUsage computes no spend from logs and applies no model pricing; a metric the provider does not
report stays hidden.

| Provider | Sign-in | Card shows |
|---|---|---|
| Claude | Browser (claude.ai OAuth) | Session, Weekly, Sonnet, Fable, Extra Usage, Rate Limit Resets |
| ChatGPT | Browser (OpenAI OAuth), with a device-code fallback | Session, Weekly, Spark, Spark Weekly, Extra Usage, Rate Limit Resets |
| Cursor | Browser (cursor.com) | Total Usage, Cursor Models, Other Models, Extra Usage, Grok Bot, Requests, Credits |
| Antigravity | Browser (Google OAuth) | Gemini 5h, Gemini, Argon, Claude 5h, Claude |
| Copilot | Device code (GitHub) | Credits, Extra Usage, Chat, Completions |
| Grok | Device code (xAI) | Weekly, Extra Usage |
| Ollama | API key | Session, Weekly, Monthly, Extra Usage |
| OpenCode | API key | Session, Weekly, Monthly |
| OpenRouter | Management API key | Balance, Today, This Week, This Month |
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
| Copilot | `read:user` | The scope Copilot's own sign-in asks for, and the one known to read `/copilot_internal/user`. It reads your GitHub profile and nothing else; whether the quota read works with no scope at all is unverified. |
| Grok | `openid profile email offline_access grok-cli:access api:access` | The set the Grok CLI itself requests. The settings and billing reads go through the Grok CLI proxy, which every known client reaches with this set; xAI publishes no narrower set for this client, so the card asks for the same. |

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
plan (Pro, Max, Team). Team seats get no weekly window from the API, so none shows.

The **Limit Resets** row counts the account's available rate-limit resets. Rest the pointer on it to see
when each expires; choose **Use**, then **Reset** to spend one.

## ChatGPT

Sign in through OpenAI in your browser. The account shows as ChatGPT; its provider id, as the command line
takes it, is `codex`. When the app cannot listen on port 1455 for the browser's
return, it offers a device code instead. The card reads `/backend-api/wham/usage` for the session and weekly windows, the Spark
windows, and extra-usage credits, and the plan (Plus, Pro, Team, Business). Rate-limit reset credits
work like Claude's Limit Resets row.

## Cursor

Sign in through cursor.com in your browser. The card reads Cursor's dashboard API for Total Usage,
Cursor Models (auto), Other Models (API), on-demand Extra Usage, Grok Bot, Requests, and Credits, and
the plan. Cursor stores the sign-in's expiry and renews it before then.

## Antigravity

Sign in with Google in your browser. The card reads the Cloud Code quota API for the Gemini and Claude
pools (5-hour and weekly windows) and the Argon weekly window, and shows the plan under the name
Google sells it as (Google AI Pro, Google AI Ultra, Google AI Ultra Lite) or the tier's own name.

## Copilot

Sign in with a GitHub device code. The card reads `/copilot_internal/user` for premium credits,
extra-usage spend, and the chat and completion counts, and the plan.

## Grok

Sign in with an xAI device code. The card reads the Grok settings and billing endpoints for the weekly
shared pool, pay-as-you-go extra usage, and the plan.

## Ollama

Paste an API key from [ollama.com/settings/keys](https://ollama.com/settings/keys). The card reads the
balance API for the session, weekly, and monthly windows that your plan has, plus purchased credits,
and the plan.

## OpenCode

Paste an API key from the [OpenCode console](https://opencode.ai/console). The card reads
`/zen/go/v1/usage` for the session, weekly, and monthly caps, and shows the plan (Go).

## OpenRouter

Paste a **Management** key from
[openrouter.ai/settings/management-keys](https://openrouter.ai/settings/management-keys). A regular
inference key cannot read the balance. The card reads `/api/v1/credits` for the balance and
`/api/v1/key` for today's, this week's, and this month's spend. Balance is the default menu-bar star.

## Z.ai

Paste an API key from the [Z.ai key list](https://z.ai/manage-apikey/apikey-list). The card reads the
GLM Coding Plan subscription and quota endpoints for the session and weekly windows, the web-search
quota, and the plan.

## Errors

A warning icon next to the account's name means the last refresh failed; the account's right-click menu
starts with the reason.
"Not logged in" or "sign in again" means the provider rejected the stored credential: remove the
account and add it again. "Rate limited" and HTTP errors clear on a later refresh. See
[Refreshing](refreshing.md).
