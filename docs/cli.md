# Command line

OpenUsage ships a one-shot `openusage` command for scripts and agents. It prints the usage the app last
fetched, as JSON, and exits. It never refreshes, signs in, or reads a credential: the app fetches on
its own schedule (every 5 minutes while it runs, see [Refreshing](refreshing.md)) and saves each
successful fetch, and the command reads that saved copy. Running it does not launch the app.

```sh
openusage                  # every account
openusage codex            # every ChatGPT account (the provider id stays codex)
openusage codex@1a2b3c4d   # one account, by its id
```

The provider argument names accounts by plain string matching. An account id (the `providers` key in
the output, `codex@1a2b3c4d`) names that account. A provider kind (`claude`, `codex`, `cursor`,
`antigravity`, `copilot`, `grok`, `ollama`, `opencode`, `openrouter`, `zai`) names every account of
that kind. Anything else is an error. There is no aliasing or account-picking logic.

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available in new terminal sessions as `/usr/local/bin/openusage`.
The installed symlink points to the signed helper inside OpenUsage, so in-place app updates also update
the command. A symlink left by another copy of OpenUsage, such as the one 0.7.x installed or a build
in another folder, is replaced on Install. **Uninstall** removes the symlink; a file or link at that
path that OpenUsage did not install is left alone and the setting reads **Unavailable**.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Printed. |
| 2 | Invalid arguments, or a provider argument that names no account. |
| 4 | Nothing fetched yet for the named accounts: open OpenUsage and add or refresh an account. The empty envelope is still printed. |

## Output

```json
{
  "schema": "openusage.limits.v1",
  "generatedAt": "2026-07-13T01:40:00.000Z",
  "providers": {
    "codex@1a2b3c4d": {
      "displayName": "ChatGPT",
      "plan": "Pro 200",
      "fetchedAt": "2026-07-13T01:39:30.000Z",
      "expiresAt": "2026-07-13T01:44:30.000Z",
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

`providers` has one entry per account, keyed by account id, never by provider: read an account as
`providers["codex@1a2b3c4d"]` (`jq '.providers["codex@1a2b3c4d"]'`). 0.7.x keyed it by provider
(`providers.codex`); that key no longer exists. An account the app has not fetched yet has no entry.
`displayName` is the provider's name and `plan` the plan the provider reports.
`fetchedAt` is when the app last fetched the account, `expiresAt` is when it expects to fetch it
again (5 minutes after `fetchedAt`), and `stale` says whether that instant has passed at `generatedAt`: a stale
entry means the app is not running or its refreshes are failing.

Each resource is one scalar with an explicit `unit`. `kind` is `consumption` (`used`) or `balance`
(`available`). Bounded consumption also carries `limit`, `remaining`, and a 0–1 `utilization`.
`resetsAt`, `windowSeconds`, and `expiresAt` (a list of instants for a balance of resets) appear only
when the provider supplies that meaning. A resource with no current value is omitted rather than
invented as zero. For bounded resources `unit` follows the provider's live format: Cursor `totalUsage`
is `percent` on percentage-based plans and `requests` on request-based Enterprise plans; Copilot
`premiumCredits` is `percent` on paid plans and a `credits` count on org-managed seats that only report
personal usage.

The command reads the last successful fetch; a failed refresh shows in the app, with its reason in
the account's right-click menu.

### Resources

| Provider | Resource keys |
| --- | --- |
| Claude | `session`, `weekly`, `sonnet`, `fable`, `extraUsage`, `rateLimitResets` |
| ChatGPT (`codex`) | `session`, `weekly`, `spark`, `sparkWeekly`, `credits`, `rateLimitResets` |
| Cursor | `totalUsage`, `grokBot`, `autoUsage`, `apiUsage`, `onDemand`, `requests`, `credits` |
| Antigravity | `geminiSession`, `geminiWeekly`, `argonWeekly`, `nonGeminiSession`, `nonGeminiWeekly` |
| Copilot | `premiumCredits`, `extraUsage`, `chat`, `completions` |
| Grok | `weekly` |
| Ollama | `session`, `weekly`, `monthly`, `purchasedCredits` |
| OpenCode | `session`, `weekly`, `monthly` |
| OpenRouter | `balance` |
| Z.ai | `session`, `weekly`, `webSearches` |

Antigravity's `argonWeekly` is the separate Gemini 4 Argon weekly quota and is omitted when the account has none.
Charts, colours, subtitles, badges, layout state, and spend periods (OpenRouter's today, week, and
month) stay out of this output.
