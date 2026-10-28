# Adding a provider

A provider is a `ProviderKind` case plus a sign-in, a usage client, and a mapper. Every value it shows
must come from the provider's API. Do not read another tool's credentials, files, or logs, and do not
compute spend from logs or model pricing.

## 1. Declare the kind

In `Sources/OpenUsage/Models/Account.swift`, add a case to `ProviderKind` with its `displayName`,
`links` (Status Page, Usage Dashboard), and `authMethod`: `.oauth`, or `.apiKey(keyPage:)` with the
page where the user creates the key.

Add the provider's mark as `Sources/OpenUsage/Resources/ProviderIcons/<kind>.svg`.

## 2. Implement the sign-in

For an API-key provider, `APIKeyLogin` already covers it; map the kind in `ProviderLoginCatalog`.

For OAuth, write a `ProviderLogin` in `Services/BrowserProviderLogins.swift` (a browser flow with
`LoopbackCallbackServer` and `PKCE`) or `Services/DeviceProviderLogins.swift` (a device-code flow
with `DeviceCodePoller`). Return the account's label (an email or the provider's account name) and its
`AccountCredential`. Map the kind in `ProviderLoginCatalog`.

## 3. Fetch and map usage

Create `Sources/OpenUsage/Providers/<Name>/` with:

- `<Name>UsageClient`: the HTTP calls, through the injected `HTTPClient`. Throw a `ProviderError`
  (`signInExpired`, `connectionFailed`, `invalidResponse`, `requestFailed`, or `unavailable` with the
  account-specific reason); `ProviderError.requireSuccess` triages a non-2xx for you. Never log a
  credential or a response body.
- `<Name>UsageMapper`: a pure function from the response to `(plan: String?, lines: [MetricLine])`.
  Validate the response here.

In `AccountProviderRuntime`, add the kind's `widgetDescriptors` (the card's metrics, each id
prefixed with the account's `cardID`) and a `refresh<Name>` case. If the provider needs a token
refresh, add it as an extension in the provider folder, as `AccountProviderRuntime+CursorAuth` does.

## 4. Defaults

Add the metrics that should be on by default to `DefaultLayout.metricIDs`, and the one or two that
should start in the menu bar to `DefaultLayout.pinnedMetricIDs`. Confirm both with the owner.

## 5. Test

Add focused tests under `Tests/OpenUsageTests/`: the mapper against recorded response bodies (success,
an empty plan, an error body), and the login's response parsing. Run `script/test_quiet.sh --filter <Name>`.

## 6. Document

Add the provider to the table and a section in `docs/providers.md`: sign-in method, what the card
shows, where the plan comes from, and what its errors mean. Add it to the provider list in
`README.md`.
