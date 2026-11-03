# CLIProxyAPI hubs

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) is a server that keeps sign-ins for
several people or machines. Connect a hub once, and every Claude, ChatGPT, Antigravity, Devin, and
Grok login on it shows in OpenUsage as an ordinary account. The hub owns the list of logins; OpenUsage
mirrors it.

## Connect a hub

1. Click **+** at the top of the Accounts screen and click **CLIProxyAPI** at the bottom of the list.
2. Enter the hub's address, such as `hub.example.com:8317` or `http://192.168.1.20:8317`, and its
   management key. A pasted panel address (`…/management.html`) or API address (`…/v0/management`)
   works too.
3. Click **Connect**. OpenUsage reads the hub's login list once. If the address or the key is wrong,
   the sheet says why and nothing is saved.

There is no list to pick from: every supported login on the hub appears at once, each at the bottom of
its provider's accounts on the dashboard, named after its email.

You can connect more than one hub. Each hub has its own row, management key, and accounts.

The hub must allow management from another machine (`allow-remote` in its config), unless it runs on
this Mac.

An address without `http://` or `https://` uses https. OpenUsage sends the management key over plain
http only when you type `http://`, and only to this Mac or the local network: `localhost`, a private
or link-local IP address, or a `.local` name. The sheet warns that the key then crosses your network
unencrypted. For any other host, use https.

## Hub accounts

A hub account has the same card, metrics, menu-bar stars, order, and reset buttons as an account you
signed in directly. Its name carries the CLIProxyAPI mark on the dashboard, and its icon carries it on
its page. In Accounts, hub accounts are listed on their hub's page, not in the list of accounts. Drag
them on the dashboard to change their order.

The hub manages its logins, so a hub account's page has no **Remove Account…**; it says
"Managed by <host>" instead, and **Back** returns to the hub's page. Renaming it, hiding metrics, and starring them work as for
any account. A login that is also signed in directly shows twice, once with the mark.

## Staying in sync

OpenUsage reads the hub's login list at launch, when the Accounts screen opens, and about once an
hour. Then:

- A login added on the hub appears at the bottom of its provider's accounts.
- A login removed on the hub disappears, with its stars, once two reads in a row miss it. A hub that
  answers while it restarts, or with a short list, removes nothing.
- A login disabled on the hub disappears, with its stars. Enabled again, it comes back as a new
  account at the bottom.
- A login renamed on the hub, or a ChatGPT login switched to another workspace, keeps its account,
  name, and stars.

If the Keychain refuses to save a login, the hub's page shows the error and the next read tries again.

Logins for providers OpenUsage doesn't support yet are not shown. That includes Cursor: the hub's Cursor
plugin holds a Cursor API key, and Cursor's usage reads need the session OpenUsage signs in with.

## The hub in Accounts

Connected hubs are listed under the accounts, one row each: the hub's address and how many accounts it
mirrors. A warning sign means the last read failed. Click the row to open the hub's page, which shows:

- The last read's error, if any.
- The accounts the hub mirrors. Click one to open its page.
- How many of the hub's logins OpenUsage doesn't support yet.

- **Replace Management Key…** checks the new key with one read of the login list before saving it.
  A refused key leaves the old key in place.
- **Remove Hub…** asks first and names how many accounts go with the hub. It deletes those accounts
  and the management key from this Mac. Nothing changes on the hub.

## When something goes wrong

| The card or row says | What happened | What to do |
|---|---|---|
| Can't reach the CLIProxyAPI hub at <host> | The hub is down or the address is wrong | Start the hub or check the address |
| … rejected the management key | The hub's key changed | **Replace Management Key…** |
| … blocked this Mac after too many wrong keys | The hub's 30-minute ban after five wrong keys | Wait, then replace the key |
| … only allows management from its own machine | `allow-remote` is off | Turn it on in the hub's config |
| … has its management API turned off | The hub has no management key, or the address isn't a hub | Set a key in its config, or fix the address |
| … has no working sign-in for this login | The hub's own sign-in for this login expired | Sign the login in again on the hub |
| This login is no longer on the CLIProxyAPI hub | The login was removed or renamed on the hub | Nothing: the next read updates the list |
| … couldn't reach Claude / ChatGPT | The hub can't reach the provider | Check the hub's network |
| OpenUsage sends a management key over http only to this Mac or the local network | The address is plain http to another host | Connect with https |
| The management key for the CLIProxyAPI hub at <host> is missing | The hub was saved by an earlier build, or its key was deleted | **Replace Management Key…**, or remove the hub |
| … isn't the address its management key was saved for | The hub's address in the app's preferences changed | Remove the hub and connect it again |

After the hub rejects the key or bans this Mac, OpenUsage sends it nothing more until you replace the
key, so a changed key never adds up to a ban. Until then, OpenUsage sends a hub one request at a
time.

## What the management key can do

The management key is the hub's admin key: it can read and change the hub's logins and settings.
OpenUsage keeps it in a Keychain service of its own (`com.robinebers.openusage.cliproxy-hubs`),
apart from account sign-ins, together with the address you connected the hub at. It sends the key only
to that address, and only ever lists the hub's logins and sends usage reads (and reset claims you
click) through the hub's `api-call`. The hub puts each login's own token into those requests, so no
provider token ever reaches this Mac.
