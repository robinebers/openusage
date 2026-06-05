# OpenAI Compatible API

Tracks token usage and estimated spend for OpenAI-compatible APIs through a local proxy.

## Setup

1. Enable **OpenAI Compatible** in Settings.
2. Set your upstream endpoint, for example:

```text
https://api.openai.com/v1
```

3. Save your upstream API key.
4. Generate or show the local token.
5. Add model prices in USD per 1M tokens.

Use this in your agent or SDK:

```text
base_url = http://127.0.0.1:6737/v1
api_key = <local token from OpenUsage>
```

The proxy forwards requests with your saved upstream key.

## Supported Routes

- `POST /v1/chat/completions`
- `POST /v1/responses`

## Pricing

Prices are matched by exact `model` name from the request body.

If a model has no configured price, OpenUsage records tokens but does not estimate cost. The provider card shows the unpriced model name.

## Streaming

Streaming is counted only when the upstream response includes a `usage` event. Missing usage is recorded as an unmetered request. OpenUsage does not estimate tokens locally.

## Files

- Non-secret settings: `settings.json`
- Usage ledger: `openai-compatible-usage.json`
- Upstream key and local token: macOS Keychain
