# Adding a provider

A provider is a `ProviderKind` case, a sign-in, a usage client, and a mapper. Every value it shows
must come from the provider's API. Never read another tool's credentials, files, or logs, and never
compute spend from logs or pricing.

## 1. Declare the kind

- Add a `ProviderKind` case in `Sources/OpenUsage/Models/Account.swift` with its `displayName`,
  `links`, and `authMethods` (`[.oauth]` or `[.apiKey(keyPage:)]`).
- Add its icon at `Sources/OpenUsage/Resources/ProviderIcons/<kind>.svg`.

## 2. Add the sign-in

- API key: `APIKeyLogin` covers it.
- Browser OAuth: add a `ProviderLogin` in `Services/BrowserProviderLogins.swift`. Send
  `UUID().uuidString` as the `state`, never the PKCE verifier.
- Device code: add it in `Services/DeviceProviderLogins.swift` with `DeviceCodePoller`.
- Pasted token: prompt `.browserToken`, as `DevinLogin` does.

Map the kind in `ProviderLoginCatalog`.

## 3. Fetch and map usage

Create `Sources/OpenUsage/Providers/<Name>/` with:

- `<Name>UsageClient`: HTTP calls through the injected `HTTPClient`, which applies the user's
  [proxy](proxy.md). Throw a `ProviderError`; `ProviderError.requireSuccess` handles non-2xx
  responses. Never log a credential or a response body.
- `<Name>UsageMapper`: a pure function from the response to `ProviderUsage`. Validate the response
  here.

Then wire up the runtime:

- Add the kind's `widgetDescriptors` in `AccountProviderRuntime+Descriptors.swift`. Chain
  `.exportingLimit(...)` on each metric the [command line](cli.md) exports.
- Add a `refresh<Name>` function and its case in `AccountProviderRuntime.swift`, and add the kind
  to the `nil` case of `resetClaimService`.
- Put any token refresh in an extension in the provider folder.

## 4. Defaults

- Every metric with data shows. Confirm the metric order with the owner before you choose it.
- A balance with no limit needs `.exportingLimit(_, kind: .balance, ...)` to count as used up at
  zero. Use it only for money or credits the user holds.

## 5. Test

Test the mapper against recorded responses (success, empty plan, error) and the login's parsing,
under `Tests/OpenUsageTests/`. Run `script/test_quiet.sh --filter <Name>`.

## 6. Document

- `docs/providers.md`: a table row and a section.
- `docs/cli.md`: the kind and its resource keys.
- `README.md` and `AGENTS.md`: the provider lists.
