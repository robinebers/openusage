# Which Providers Are On

How OpenUsage decides which providers start on, what happens when an update adds a new provider, and the one rule that governs it all: **your own toggles always win and are never overridden.**

## First install

On the first launch, a welcome screen looks for existing sign-ins without requesting Keychain access or contacting providers. Choose the providers you want, then click **Connect Selected**. Only the selected providers are connected, one at a time. macOS may ask for access to their saved sign-ins; **Always Allow** lets later background updates read the same items.

Failed connections stay on the welcome screen with a retry option. **Open Dashboard** enables the providers that connected successfully. **Skip for Now** opens the dashboard with no providers enabled; use Customize to enable a provider later. Turning a provider on immediately requests any needed access. Closing the app before completing setup shows the welcome screen again next time.

Detection is evidence of a local sign-in, not proof that it is valid. A protected Keychain entry can appear as detected before its contents have been read. Background refreshes never intentionally request Keychain authorization: when access is needed, the provider asks you to use Refresh.

## When an update adds a new provider

The same detection runs for providers that arrive later. On the first launch after an update, OpenUsage compares the providers it now ships with the ones this install has seen before. For each brand-new one, it runs the same local-only credential check:

- **Credentials are available locally** → the provider turns on and appears on the dashboard.
- **No credentials are available** → it stays off. You can always turn it on later in **Customize**.

A newly discovered account for a provider you already know is not treated as a new provider; it cannot turn a skipped or disabled provider back on.

This check happens **once per provider**. After that, the provider is yours to manage: if you turn it off, no update will ever turn it back on, and installing the tool later won't flip it on behind your back either — head to Customize when you want it.

## Your choices always stick

Everything you set in Customize — providers on or off, metric layout, menu-bar stars — carries across updates untouched. The only thing an update may ever change is turning **on** a provider you have never seen before, and only when you actually have that tool installed.

The one exception is deliberate: the **Reset All Customization** button at the top of the Customize provider list. Because you asked for a clean slate, it re-runs the same local credential detection as first launch and switches the enabled set back to exactly the providers with credentials available on your Mac (Claude/Codex/Cursor if none are found) — so it can turn a provider off even if you had it on, or back on if you had turned it off. It also asks for confirmation first. See [Dashboard](dashboard.md) for the metric side of that reset.

## How it works (for the curious)

The app persists three small lists in its settings:

- **Enabled providers** — the providers currently on. This is the source of truth the dashboard and menu bar read.
- **Known providers** — every provider this install has ever seen. This is what makes "new in this update" distinguishable from "you turned it off": a provider missing from the enabled list but present in the known list is a deliberate choice, and is left alone. Only providers missing from *both* get the credential check, and each is marked known immediately so the check never repeats.
- Each provider implements a cheap, local-only credential probe (`hasLocalCredentials()`) — the same files, keychain entries, saved keys, and environment variables its normal refresh reads, never the network.

Older installs (from before first-run detection existed) started with every provider on and stored only the ones turned *off*. A one-time settings migration converts them to the lists above with the exact same providers on and off as before — nothing visibly changes on the launch that migrates; those installs simply join the same new-provider detection from then on.
