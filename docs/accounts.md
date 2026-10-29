# Accounts

The Accounts screen lists every account you have added, or reads **No Accounts** until you add one.
Open it from the panel's **Options** menu or press Return on the dashboard.

## Add an account

1. Click **+** at the top of the Accounts screen.
2. Click a provider, or select it with the arrow keys and press Return. The sign-in starts at once.
   Copilot asks first: **Sign In with GitHub** for your own seat, or **Organization Billing** for an
   organization's credits and spend.
3. Finish the sign-in:
   - **Browser** (Claude, ChatGPT, Cursor, Antigravity): your browser opens on its own. **Open Browser**
     opens it again, and **Copy Link** lets you open the link in another browser. The sheet closes
     when you are signed in. If your browser shows a code instead, paste it into the sheet and click
     **Continue**.
   - **Browser and token** (Devin): your browser opens Windsurf's sign-in. Sign in, copy the token the
     page shows, paste it into the sheet, and click **Continue**. A token expires after 5 minutes. A
     Windsurf API key works in place of the token.
   - **Device code** (Copilot, Grok): the sheet shows a code. **Copy Code**, click **Open Browser**,
     and enter the code. The sheet closes when the provider confirms.
   - **API key** (Ollama, OpenCode, OpenRouter, Z.ai): create a key on the page the sheet links to,
     paste it, and click **Add Account**. The key is added only once a usage read accepts it.
   - **Organization Billing** (Copilot): enter the organization and a token from one of its owners or
     billing managers, and click **Add Account**. The account is named after the organization, and the
     same organization is not added twice.

To add the Claude and ChatGPT logins of a CLIProxyAPI server, click **CLIProxyAPI** at the bottom of
the list and enter the hub's address and management key. See [CLIProxyAPI hubs](cliproxyapi.md).

If a sign-in fails, **Try Again** starts it over. The close button in a sign-in step's corner (or Esc)
goes back to the provider list; **Cancel** on the list closes the sheet.

You can add several accounts for the same provider. A new account goes to the bottom of its
provider's accounts and starts refreshing right away. A new account takes the email or name the
provider reports. An Ollama account takes the email ollama.com reports for its key. Any other API-key
account reports neither, so it shows the provider's name once.
Signing in to an account that's already added (the same provider account, or the same API key) adds
no second copy; the sheet says "This account is already added as <name>." If a CLIProxyAPI hub already
provides it, the sheet says it is already in OpenUsage through the hub. A Claude account in two organizations counts as two accounts, and so does a
Devin email in two organizations.

## Rename an account

Click the name at the top of the account's page, double-click it on the dashboard, or choose
**Rename** from its right-click menu. The field opens with the whole name selected. Return or a click
elsewhere saves; Esc cancels.

## Replace an API key

**Replace API Key…** on an API-key account's page takes a new key and checks it with one usage read
before saving it. The account keeps its name, place, and stars; if the provider refuses the key, the
old key stays and the page shows why. A Copilot organization account has **Replace Token…** instead.

## Hide and star metrics

An account's page lists its metrics with a switch and a star each. Turn a metric off to hide it from
the dashboard and the menu bar; hiding it also removes its star. Star a metric to show it in the menu
bar; see [Menu bar](menu-bar.md).

## Remove an account

**Remove Account…** sits at the bottom of the account's page. Removing an account deletes its sign-in
from this Mac. You can add the account again at any time. If the Keychain refuses to delete the
sign-in, the account stays and its page shows why. An account from a CLIProxyAPI hub has no
**Remove Account…**: remove the login on the hub, or remove the whole hub from its row in Accounts.

## Where things are stored

Account names and the dashboard layout live in the app's own preferences. OAuth tokens and API keys
live in the app's own Keychain service, and so does a CLIProxyAPI hub's management key. OpenUsage never reads credentials, files, Keychain items,
databases, or environment variables that belong to other tools.

A version of OpenUsage that cannot read one of your accounts, such as one for a provider that version
lacks, leaves it out of the list and keeps it saved, with its sign-in, for a version that reads it.
