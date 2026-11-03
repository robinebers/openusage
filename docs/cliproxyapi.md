# CLIProxyAPI hubs

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) is a server that keeps sign-ins for
several people or machines. Connect a hub, and its Claude, ChatGPT, Antigravity, Devin, and Grok
logins show in OpenUsage as ordinary accounts.

- The hub owns the list of logins. OpenUsage mirrors it.
- You can connect more than one hub.
- The hub must allow remote management (`allow-remote` in its config), unless it runs on this Mac.

## Connect a hub

1. Click **Add New Account** at the bottom of the Accounts screen, then **CLIProxyAPI**.
2. Enter the hub's address, such as `hub.example.com:8317`, and its management key. A pasted panel
   address (`…/management.html`) or API address (`…/v0/management`) works too.
3. Click **Connect**. If the address or key is wrong, the sheet says why and nothing is saved.

Every supported login on the hub appears at once, named after its email.

An address without a scheme uses https. Plain `http://` works only for this Mac, the local network
(`localhost`, private or link-local IPs, `.local` names), and Tailscale (`….ts.net`,
`100.64.0.0/10`, `fd7a:115c:a1e0::/48`).

## Hub accounts

A hub account works like any other account and carries the CLIProxyAPI mark.

- It is listed on its hub's page in Accounts.
- The hub manages it, so it has no **Remove Account…**.
- A login that is also signed in directly shows twice.

## Staying in sync

OpenUsage reads the hub's login list at launch, when Accounts opens, and about once an hour.

- A login added on the hub appears at the bottom of its provider's accounts.
- A login removed on the hub disappears once two reads in a row miss it.
- A login disabled on the hub disappears. Enabled again, it comes back as a new account.
- A renamed login, or a ChatGPT login on another workspace, keeps its account, name, and Priority
  pins.

Logins for unsupported providers don't show. That includes Cursor, because the hub holds a Cursor
API key and Cursor's usage reads need OpenUsage's own sign-in.

## The hub in Accounts

Each hub has a row under the accounts. A warning sign means the last read failed. The hub's page
shows the last error, its accounts, and how many logins aren't supported yet.

- **Replace Management Key…** tests the new key before saving it. A refused key keeps the old one.
- **Remove Hub…** deletes the hub's accounts and key from this Mac. Nothing changes on the hub.

## When something goes wrong

| The card or row says | Fix |
|---|---|
| Can't reach the CLIProxyAPI hub at <host> | Start the hub or check the address |
| … rejected the management key | **Replace Management Key…** |
| … blocked this Mac after too many wrong keys | Wait out the 30-minute ban, then replace the key |
| … only allows management from its own machine | Turn on `allow-remote` in the hub's config |
| … has its management API turned off | Set a management key in the hub's config, or fix the address |
| … has no working sign-in for this login | Sign the login in again on the hub |
| This login is no longer on the CLIProxyAPI hub | Nothing. The next read updates the list |
| … couldn't reach Claude / ChatGPT | Check the hub's network |
| Use https for <host> | Connect with https |
| This hub doesn't use https | Connect with the http address it gives |
| The management key for the CLIProxyAPI hub at <host> is missing | **Replace Management Key…**, or remove the hub |
| … isn't the address its management key was saved for | Remove the hub and connect it again |

After the hub rejects the key or bans this Mac, OpenUsage sends it nothing until you replace the
key.

## What the management key can do

The management key is the hub's admin key. It can read and change the hub's logins and settings.

- OpenUsage keeps it in its own Keychain service, `com.robinebers.openusage.cliproxy-hubs`.
- It sends the key only to the address you connected.
- It only lists logins and sends usage reads and reset claims through the hub's `api-call`. The hub
  adds each login's token, so no provider token reaches this Mac.
