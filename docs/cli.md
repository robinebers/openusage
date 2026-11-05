# Command line

`openusage` prints the usage the app last fetched, as JSON, and exits. It never refreshes, signs in,
reads a credential, or launches the app. The app fetches every 5 minutes while it runs (see
[Refreshing](refreshing.md)).

```sh
openusage                  # every account
openusage codex            # every ChatGPT account (the provider id stays codex)
openusage codex@1a2b3c4d   # one account, by its id
```

- The argument is an account id (the `providers` key in the output) or a provider kind: `claude`,
  `codex`, `cursor`, `antigravity`, `copilot`, `devin`, `grok`, `muse`, `ollama`, `opencode`,
  `openrouter`, `zai`. Anything else is an error.
- `--force` from 0.7.x is accepted and does nothing. The command says so on stderr.

## Install on `PATH`

- **Settings → Command Line → Install…** asks for an administrator password, then links
  `/usr/local/bin/openusage` to the helper inside OpenUsage. App updates update the command too.
- Install replaces a link left by another copy of OpenUsage, such as the one 0.7.x installed.
- **Uninstall** removes the link. A file at that path that OpenUsage didn't install is left alone, and
  the setting reads **Unavailable**.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Printed. |
| 2 | Invalid arguments, or a provider argument that names no account. |
| 4 | Nothing fetched yet for the named accounts. Open OpenUsage and add or refresh an account. The empty envelope still prints. |

## Output

```json
{
  "schema": "openusage.limits.v2",
  "generatedAt": "2026-07-13T01:40:00.000Z",
  "providers": {
    "codex@1a2b3c4d": {
      "displayName": "ChatGPT · Work",
      "plan": "Pro 200",
      "fetchedAt": "2026-07-13T01:39:30.000Z",
      "expiresAt": "2026-07-13T01:49:30.000Z",
      "stale": false,
      "resources": {
        "session": {
          "kind": "consumption",
          "unit": "percent",
          "used": 42,
          "limit": 100,
          "remaining": 58,
          "utilization": 0.42,
          "resetsAt": "2026-07-13T06:00:00.000Z",
          "windowSeconds": 18000
        },
        "credits": {
          "kind": "balance",
          "unit": "credits",
          "available": 821
        }
      }
    }
  }
}
```

| Field | Meaning |
| --- | --- |
| `providers` | One entry per account, keyed by account id. An account not fetched yet, or for a provider this version lacks, has no entry. |
| `displayName` | The provider and account name as the app shows them. |
| `plan` | The plan the provider reports. |
| `fetchedAt` | When the app last fetched the account successfully. |
| `expiresAt` | 10 minutes after `fetchedAt`, two refresh intervals. |
| `stale` | `expiresAt` has passed. The app isn't running, or its refreshes of that account are failing. |

Each resource is one value with a `unit`:

- `kind` is `consumption` (`used`) or `balance` (`available`).
- Bounded consumption adds `limit`, `remaining`, and a 0–1 `utilization`.
- `resetsAt`, `windowSeconds`, and `expiresAt` (a list of instants for a balance of resets) appear
  only when the provider supplies them.
- A resource with no current value is left out, not shown as zero.
- `unit` follows the provider's live format. Cursor `totalUsage` is `percent`, or `requests` on
  request-based Enterprise plans. Copilot `premiumCredits` is `percent` on paid plans, or a
  `credits` count on org-managed seats that only report personal usage. Claude `extraUsage` is the
  account's billing currency, such as `usd` or `eur`.

A failed refresh doesn't change the output. The app shows the failure, with its reason in the
account's right-click menu.

### Resources

| Provider | Resource keys |
| --- | --- |
| Claude | `session`, `weekly`, `sonnet`, `fable`, `extraUsage`, `rateLimitResets` |
| ChatGPT (`codex`) | `session`, `weekly`, `spark`, `sparkWeekly`, `credits`, `rateLimitResets` |
| Cursor | `totalUsage`, `grokBot`, `autoUsage`, `apiUsage`, `onDemand`, `requests`, `credits` |
| Antigravity | `geminiSession`, `geminiWeekly`, `argonWeekly`, `nonGeminiSession`, `nonGeminiWeekly` |
| Copilot | `premiumCredits`, `extraUsage`, `chat`, `completions`; an organization account: `orgCredits`, `orgSpend` |
| Devin | `daily`, `weekly`, `extraUsageBalance` |
| Grok | `weekly` |
| Muse Code | `session`, `weekly` |
| Ollama | `session`, `weekly`, `monthly`, `purchasedCredits` |
| OpenCode | `session`, `weekly`, `monthly` |
| OpenRouter | `balance`, `keyLimit` |
| Z.ai | `session`, `weekly`, `webSearches`, `rateLimitResets` |

- ChatGPT `credits` is `0` when the balance is empty, and absent when ChatGPT reports no balance.
- Antigravity `argonWeekly` is the Gemini 4 Argon weekly quota, absent when the account has none.
- Charts, subtitles, badges, layout, and spend periods (such as OpenRouter's today, week, and month)
  aren't in the output.
