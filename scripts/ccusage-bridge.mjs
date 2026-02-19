import { loadDailyUsageData } from 'ccusage/data-loader'

const opts = JSON.parse(process.argv[2] || '{}')
const provider = opts._provider || 'claude'

const adapters = {
  claude: () => loadDailyUsageData({
    since: opts.since,
    until: opts.until,
    claudePath: opts.claudePath,
    order: 'desc',
  }),
}

const handler = adapters[provider]
if (!handler) {
  console.log(JSON.stringify({ daily: [] }))
  process.exit(0)
}

const daily = await handler()

// Add totalTokens (library API doesn't include it, CLI --json does)
for (const d of daily) {
  d.totalTokens = (d.inputTokens || 0) + (d.outputTokens || 0)
    + (d.cacheCreationTokens || 0) + (d.cacheReadTokens || 0)
}

console.log(JSON.stringify({ daily }))
process.exit(0)
