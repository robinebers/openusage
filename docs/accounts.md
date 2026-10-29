# Accounts

The Accounts screen lists every account you have added, or reads **No Accounts** until you add one.
Open it from the panel's **Options** menu or press Return on the dashboard.

## Add an account

1. Click **+** at the top of the Accounts screen.
2. Click a provider, or select it with the arrow keys and press Return. The sign-in starts at once.
3. Finish the sign-in:
   - **Browser** (Claude, ChatGPT, Cursor, Antigravity): your browser opens on its own. **Open Browser**
     opens it again, and **Copy Link** lets you open the link in another browser. The sheet closes
     when you are signed in. If your browser shows a code instead, paste it into the sheet and click
     **Continue**.
   - **Device code** (Copilot, Grok): the sheet shows a code. **Copy Code**, click **Open Browser**,
     and enter the code. The sheet closes when the provider confirms.
   - **API key** (Ollama, OpenCode, OpenRouter, Z.ai): create a key on the page the sheet links to,
     paste it, and click **Add Account**.

If a sign-in fails, **Try Again** starts it over. The close button in a sign-in step's corner (or Esc)
goes back to the provider list; **Cancel** on the list closes the sheet.

You can add several accounts for the same provider. A new account goes to the bottom of its
provider's accounts and starts refreshing right away. Signing in to an account that's already added
(the same provider account, or the same API key) adds no second copy; the sheet says "This account is
already added as <name>." A Claude account in two organizations counts as two accounts.

## Rename an account

Click the name at the top of the account's page, double-click it on the dashboard, or choose
**Rename** from its right-click menu. The field opens with the whole name selected. Return or a click
elsewhere saves; Esc cancels.

## Replace an API key

**Replace API Key…** on an API-key account's page takes a new key and checks it with one usage read
before saving it. The account keeps its name, place, and stars; if the provider refuses the key, the
old key stays and the page shows why.

## Hide and star metrics

An account's page lists its metrics with a switch and a star each. Turn a metric off to hide it from
the dashboard and the menu bar; hiding it also removes its star. Star a metric to show it in the menu
bar; see [Menu bar](menu-bar.md).

## Remove an account

**Remove Account…** sits at the bottom of the account's page. Removing an account deletes its sign-in
from this Mac. You can add the account again at any time.

## Where things are stored

Account names and the dashboard layout live in the app's own preferences. OAuth tokens and API keys
live in the app's own Keychain service. OpenUsage never reads credentials, files, Keychain items,
databases, or environment variables that belong to other tools.
