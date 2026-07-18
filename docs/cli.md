# Command-Line Interface

OpenUsage ships a one-shot `openusage` command for agents and scripts. It prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits; it never launches or leaves the menu-bar
app running. The output contains stable scalar limits and balances, not UI rows, colors, subtitles,
charts, or spend-history tiles.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` is the CLI equivalent of the app's manual refresh: it bypasses that freshness gate and
writes successful results to the same cache. Credentials are used locally and never appear in the output.

The `claude` and `codex` IDs select the account signed in at the provider's default home (the same
account the app's card shows), so existing usage keeps working unchanged as multi-account support
arrives. When no default login exists and exactly one card of that family is enabled, the bare ID
answers with that card instead of an empty result.

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside OpenUsage, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments, `3` when a requested provider has no snapshot,
and `4` when a refresh or local read fails.
