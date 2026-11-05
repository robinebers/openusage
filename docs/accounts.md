# Accounts

The Accounts screen lists your accounts. Open it from the panel's **⋯** menu or press Return
on the dashboard.

## Add an account

1. Click **Add New Account**.
2. Pick a provider. Copilot first asks for **Sign In with GitHub** (your own seat) or
   **Organization Billing** (an organization's credits and spend). **Sign In with GitHub** then asks
   for a domain: leave it blank for github.com, or enter your company's GHE.com address.
3. Finish the sign-in:

| Sign-in | Providers | What to do |
|---|---|---|
| Browser | Claude, ChatGPT, Cursor, Antigravity | Sign in in the browser that opens. If it shows a code, paste it and click **Continue**. |
| Browser and token | Devin | Sign in to Windsurf, paste the token it shows (valid for 5 minutes) or a Windsurf API key, and click **Continue**. |
| Device code | Copilot, Grok, Muse Code | Copy the code, click **Open Browser**, and enter it if the page doesn't fill it in. |
| API key | Ollama, OpenCode, OpenRouter, Z.ai | Create a key on the linked page, paste it, and click **Add Account**. |
| Organization billing | Copilot | Enter the organization and a token from an owner or billing manager, and click **Add Account**. |

If a sign-in fails, click **Try Again**.

To add the logins of a CLIProxyAPI server, click **CLIProxyAPI** at the bottom of the list. See
[CLIProxyAPI hubs](cliproxyapi.md).

- You can add several accounts per provider. A new account goes to the bottom of its provider's
  accounts.
- An account takes the email or name the provider reports. API-key accounts other than Ollama
  are named after the provider, such as "OpenRouter Account".
- A sign-in or key you already use isn't added twice.
- A Claude account or Devin email in two organizations counts as two accounts, and so does a GitHub
  user on github.com and on a GHE.com domain.

## Rename an account

Click the name on the account's page, double-click it on the dashboard, or choose **Rename** from
its right-click menu. Return saves and Esc cancels.

## Hide, pin, and order metrics

An account's page has a switch, a pin, and a drag handle for each metric. See
[Hiding, pinning, and ordering metrics](dashboard.md#hiding-pinning-and-ordering-metrics).

## Replace an API key

**Replace API Key…** on the account's page checks the new key with one usage read before saving
it. If the provider refuses it, the old key stays. Copilot organization accounts have
**Replace Token…** instead.

## Remove an account

**Remove Account…** at the bottom of the account's page deletes its sign-in from this Mac. For an
account from a CLIProxyAPI hub, remove the login on the hub or remove the whole hub.

## Where things are stored

Account names and the dashboard layout live in the app's preferences. Tokens and keys live in the
app's own Keychain services. OpenUsage never reads other tools' credentials, files, Keychain items,
databases, or environment variables.

## Sign in again

When a sign-in expires, click **Sign In Again…** on the account's page. The account keeps its
name, place, and settings. A Copilot account on GHE.com signs in again at its own domain. In Priority, **Fix** on an account under **Needs Attention** opens
that page.
