# Qoder

Tracks [Qoder](https://qoder.com) personal usage quotas from the local Qoder CLI account.

## What it tracks

| Metric | Meaning |
|---|---|
| Monthly | Percent used from your main monthly plan quota |
| Add-on Credits | Credits used from your add-on quota, when Qoder returns one |
| Org Credits | Credits used from an organization resource package, when Qoder returns one |

## Where credentials come from

OpenUsage reuses your local `qodercli` login.
It checks `qodercli status --output json` to confirm that Qoder is installed and signed in, then asks the CLI for usage through the same local SDK control path Qoder documents as `getUsageInfo()`.

If the CLI is installed but you are not signed in, OpenUsage can also use the `QODER_PERSONAL_ACCESS_TOKEN` environment variable.
The CLI is still required because Qoder's personal usage endpoint is exposed through `qodercli`.

OpenUsage does not read Qoder token files directly and does not send usage through Qoder Teams OpenAPI yet.

## Setup

1. Install Qoder CLI from [qoder.com](https://qoder.com).
2. Run `qodercli login` and sign in through the browser, or export a personal access token:

```bash
export QODER_PERSONAL_ACCESS_TOKEN="YOUR_TOKEN"
```

3. Qoder appears on the dashboard after the next provider-detection or refresh pass.

## Under the hood

OpenUsage starts `qodercli` in stream-json mode and sends two local control requests: `initialize`, then `get_usage_info`.
The CLI returns Qoder's `UsageInfo` payload, including `userQuota`, optional `addOnQuota`, optional `orgResourcePackage`, and `totalUsagePercentage`.
OpenUsage shows the main `userQuota` bucket as Monthly percentage remaining and does not render `totalUsagePercentage` as a separate row because it duplicates the same monthly quota at a percentage level.

Optional buckets are not faked.
If Qoder does not return add-on or organization credits for your account, those rows show no data until Qoder reports them.

## Troubleshooting

- **"Qoder CLI not installed"** — install `qodercli`, or set `QODERCLI_PATH` if it is outside your normal `PATH`.
- **"Qoder is not logged in"** — run `qodercli login`, or export `QODER_PERSONAL_ACCESS_TOKEN`.
- **"Qoder authentication failed"** — sign in again or rotate your personal access token.
- **"Qoder CLI does not support usage info"** — update Qoder CLI.
