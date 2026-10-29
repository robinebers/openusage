# CLIProxyAPI hubs

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) is a server that keeps Claude and ChatGPT
sign-ins for several people or machines. Connect a hub once, and every Claude and ChatGPT login on it
shows in OpenUsage as an ordinary account. The hub owns the list of logins; OpenUsage mirrors it.

## Connect a hub

1. Click **+** at the top of the Accounts screen and click **CLIProxyAPI** at the bottom of the list.
2. Enter the hub's address, such as `http://192.168.1.20:8317`, and its management key. A pasted
   panel address (`…/management.html`) or API address (`…/v0/management`) works too.
3. Click **Connect**. OpenUsage reads the hub's login list once. If the address or the key is wrong,
   the sheet says why and nothing is saved.

There is no list to pick from: every Claude and ChatGPT login on the hub appears at once, each at the
bottom of its provider's accounts, named after its email.

The hub must allow management from another machine (`allow-remote` in its config), unless it runs on
this Mac. Use `https`, an IP address, or a `.local` name: macOS refuses plain `http` to other names.

## Hub accounts

A hub account has the same card, metrics, menu-bar stars, order, and reset buttons as an account you
signed in directly. Its icon carries the CLIProxyAPI mark in the corner, in Accounts and on its page.

The hub manages its logins, so a hub account's page has no **Remove Account…**; it says
"Managed by CLIProxyAPI at <host>" instead. Renaming it, hiding metrics, and starring them work as for
any account.

## A login you also signed in directly

The account that was in OpenUsage first wins, so no login shows twice:

- A hub login you already signed in directly gets no hub account. Your direct account keeps its
  name, stars, and place, and the hub's row counts it as already added directly. For a Claude login,
  OpenUsage reads its profile once through the hub to tell which login it is; until that read works,
  the login is not shown.
- Signing in directly to a login the hub already provides adds nothing; the sheet says "This account
  is already in OpenUsage through the CLIProxyAPI hub at <host>."
- Removing the direct account lets the hub's copy appear at the next read, at the bottom of its
  provider's accounts with the default stars.

## Staying in sync

OpenUsage reads the hub's login list at launch, when the Accounts screen opens, about once an hour,
and shortly after a refresh finds one of the hub's logins gone. Then:

- A login added on the hub appears at the bottom of its provider's accounts.
- A login removed on the hub disappears, with its stars.
- A login disabled on the hub stays, and its card's warning says it is disabled.
- A login renamed on the hub keeps its account, name, and stars.

Logins for providers OpenUsage doesn't support yet are not shown.

## The hub's row

Each connected hub has a row under the accounts. It shows the hub's address, how many accounts it
mirrors, how many of its logins OpenUsage doesn't support yet or you already added directly, and the
last read's error, if any.

- **Replace Management Key…** checks the new key with one read of the login list before saving it.
  A refused key leaves the old key in place.
- **Remove Hub…** asks first and names how many accounts go with the hub. It deletes those accounts
  with their stars, and the management key from this Mac. Accounts you signed in directly stay. Nothing
  changes on the hub. Connecting the hub again adds its accounts fresh, with the default stars.

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

After the hub rejects the key or bans this Mac, OpenUsage sends it nothing more until you replace the
key, so a changed key never adds up to a ban. Until then, OpenUsage sends a hub one request at a
time.

## What the management key can do

The management key is the hub's admin key: it can read and change the hub's logins and settings.
OpenUsage keeps it in the app's Keychain service and only ever lists the hub's logins and sends usage
reads (and reset claims you click) through the hub's `api-call`. The hub puts each login's own token
into those requests, so no Claude or ChatGPT token ever reaches this Mac.
