# Kimi

Tracks your Kimi Code subscription quota using the login you already have from the Kimi CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day subscription quota used |

Both are reported by Moonshot as percentages, so there are no token or request counts to show — and no
spend tiles, since there is nothing to price. When Kimi reports your membership level, OpenUsage shows it
beside the provider name.

## Where credentials come from

Sign in with the Kimi CLI (`kimi`); OpenUsage reads the existing login. It checks these files in order —
whichever holds a usable token first wins:

1. `$KIMI_CODE_HOME/credentials/kimi-code.json` (default `~/.kimi-code/…`) — the shipped CLI's layout
2. `$KIMI_SHARE_DIR/credentials/kimi-code.json` (default `~/.kimi/…`) — the upstream CLI's layout

There is no Keychain involved: the CLI retired keyring storage and now keeps the token in a private
(`0600`) JSON file.

Kimi access tokens last only about **15 minutes**, so OpenUsage refreshes them itself rather than waiting
for the CLI. Before refreshing it re-reads the file, in case `kimi` rotated the token first, and it holds
the same lock file the CLI uses so the two can't refresh at the same time. The rotated token is written
back into the CLI's own file — merged in, so anything else stored there is preserved — which is what keeps
your `kimi` session working. If that write ever fails, OpenUsage logs it loudly and uses the refreshed
token for the current session only.

If your subscription's `KIMI_CODE_BASE_URL` or OAuth host is pointed somewhere custom, OpenUsage honors
the same environment variables the CLI does.

## Troubleshooting

- **"Not logged in"** — run `kimi` and sign in, then refresh.
- **"Session expired"** — the saved login was rejected. Run `kimi` and sign in again.
- **"Kimi credentials couldn't be read"** — the credentials file exists but isn't valid JSON. Run `kimi`
  to sign in again and rewrite it.
- **Session shows `0% left`** — the 5-hour window is exhausted. It recovers on its own at the reset time
  shown under the meter, even if weekly quota remains.
- **"Kimi quota data unavailable"** — the account has no Kimi Code quota to report (for example an
  API-key-only account, which is a separate product from the subscription).

## Under the hood

`GET https://api.kimi.com/coding/v1/usages` with the OAuth access token. Tokens refresh via
`POST https://auth.kimi.com/api/oauth/token`.

The weekly figure comes from the response's `usage` block; the Session meter is the 5-hour entry in its
`limits` array, matched by window duration. Any other rate window in that array is written to the log
rather than dropped silently, so a new one shows up instead of vanishing.

**This endpoint is unofficial.** It is not in Moonshot's published API reference — it is the same one the
Kimi CLI's own `/usage` command calls. Moonshot can change it without notice; if that happens the card
reports that quota data is unavailable rather than showing wrong numbers.

When the five-hour window has no usage yet, the Session row shows **Not started**.
