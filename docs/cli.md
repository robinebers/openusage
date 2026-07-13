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

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside OpenUsage, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments, `3` when a requested provider has no snapshot,
and `4` when a refresh or local read fails.
