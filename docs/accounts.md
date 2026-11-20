# Accounts

The Accounts screen lists your accounts. Open it from the panel's **⋯** menu or press Return
on the dashboard.

## Add an account

1. Click **Add New Account**.
2. Pick a provider. Copilot first asks for **Sign In with GitHub** (your own seat) or
   **Organization Billing** (an organization's credits and spend). **Sign In with GitHub** then asks
   for a domain: leave it blank for github.com, or enter your company's GHE.com address. Claude first
   asks for **Sign In with Browser** or **Long-Lived Token**.
3. Finish the sign-in:

| Sign-in | Providers | What to do |
|---|---|---|
| Browser | Claude, ChatGPT, Cursor, Antigravity, Devin | Sign in in the browser that opens. If it shows a code, paste it and click **Continue**. |
| Device code | Amp, Copilot, Grok, Muse Code, OpenCode | Copy the code, click **Open Browser**, and enter it if the page doesn't fill it in. |
| API key | DeepSeek, Ollama, OpenRouter, Plivo, Z.ai | Create a key on the linked page, paste it, and click **Add Account**. Plivo takes its Auth ID and Auth Token as `AUTH_ID:AUTH_TOKEN`. |
| Organization billing | Copilot | Enter the organization and a token from an owner or billing manager, and click **Add Account**. |
| Long-lived token | Claude | Paste a token from `claude setup-token` and click **Add Account**. |

A Claude long-lived token can't read Claude's usage page, so OpenUsage sends one small model request
per refresh and reads the limits Claude reports with it. It shows the Session, Weekly, and Fable limits
Claude reports and no plan, Sonnet limit, extra usage, or resets. The request goes to Fable, whose
answer carries the Fable limit. To replace the token, remove the
account and add it again.

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

## Pick an account's currency

An account that shows money has a **Currency** picker on its page. Leave it at Same as Settings, or
pick As Reported or a currency such as Indian Rupee for that account alone. See
[Currency](settings.md#currency).

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
