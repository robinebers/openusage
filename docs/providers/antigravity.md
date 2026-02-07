# Antigravity

> Reverse-engineered from app bundle and language server binary. May change without notice.

Antigravity is essentially a Google-branded fork of [Windsurf](windsurf.md) — both use the same Codeium language server binary and Connect-RPC protocol. The discovery, port probing, and RPC endpoints are virtually identical. The key differences: Antigravity uses fraction-based per-model quota (not credits), and doesn't require an API key in the request metadata.

## Overview

- **Vendor:** Google (internal codename "Jetski")
- **Protocol:** Connect RPC v1 (JSON over HTTP) on local language server
- **Service:** `exa.language_server_pb.LanguageServerService`
- **Auth:** CSRF token from process args (no API key needed)
- **Quota:** fraction (0.0–1.0, where 1.0 = 100% remaining)
- **Quota window:** 5 hours
- **Timestamps:** ISO 8601
- **Requires:** Antigravity IDE running (language server is a child process)

## Discovery

The language server listens on a random localhost port. Three values must be discovered from the running process.

```bash
# 1. Find process and extract CSRF token
ps -ax -o pid=,command= | grep 'language_server_macos.*antigravity'
# Match: --app_data_dir antigravity  OR  path contains /antigravity/
# Extract: --csrf_token <token>
# Extract: --extension_server_port <port>  (HTTP fallback)

# 2. Find listening ports
lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>

# 3. Probe each port to find the Connect-RPC endpoint
POST https://127.0.0.1:<port>/.../GetUnleashData  → first 200 OK wins
```

Port and CSRF token change on every IDE restart. The LS may use HTTPS with a self-signed cert.

## Headers (all local requests)

| Header | Required | Value |
|---|---|---|
| Content-Type | yes | `application/json` |
| Connect-Protocol-Version | yes | `1` |
| x-codeium-csrf-token | yes | `<csrf_token>` (from process args) |

## Endpoints

### GetUserStatus (primary)

Returns plan info and per-model quota for all models (Gemini, Claude, GPT-OSS) in a single call.

```
POST http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus
```

#### Request

```json
{
  "metadata": {
    "ideName": "antigravity",
    "extensionName": "antigravity",
    "ideVersion": "unknown",
    "locale": "en"
  }
}
```

No API key needed — the CSRF token alone authenticates. (Windsurf requires `metadata.apiKey`.)

#### Response

```jsonc
{
  "userStatus": {
    "planStatus": {
      "planInfo": {
        "planName": "Pro",                       // "Free" | "Pro" | "Teams" | "Ultra"
        "teamsTier": "TEAMS_TIER_PRO"
      }
    },

    "cascadeModelConfigData": {
      "clientModelConfigs": [
        {
          "label": "Gemini 3 Pro (High)",
          "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M7" },
          "quotaInfo": {
            "remainingFraction": 1,              // 0.0–1.0
            "resetTime": "2026-02-07T14:23:01Z"
          }
        },
        {
          "label": "Claude Sonnet 4.5",
          "quotaInfo": { "remainingFraction": 1, "resetTime": "..." }
        },
        {
          "label": "Claude Opus 4.5 (Thinking)",
          "quotaInfo": { "remainingFraction": 1, "resetTime": "..." }
        },
        {
          "label": "GPT-OSS 120B (Medium)",
          "quotaInfo": { "remainingFraction": 1, "resetTime": "..." }
        }
        // ~7 models total, dynamic
      ]
    }
  }
}
```

### GetCommandModelConfigs (fallback)

Returns model configs with per-model quota only. No plan info, no email. Use when `GetUserStatus` fails.

```
POST http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs
```

#### Request

```json
{
  "metadata": {
    "ideName": "antigravity",
    "extensionName": "antigravity",
    "ideVersion": "unknown",
    "locale": "en"
  }
}
```

#### Response

```jsonc
{
  "clientModelConfigs": [
    // same shape as GetUserStatus.cascadeModelConfigData.clientModelConfigs
  ]
}
```

## Available Models

| Display Name | Internal ID | Provider |
|---|---|---|
| Gemini 3 Flash | 1018 | Google |
| Gemini 3 Pro (High) | 1008 | Google |
| Gemini 3 Pro (Low) | 1007 | Google |
| Claude Sonnet 4.5 | 333 | Anthropic (proxied) |
| Claude Sonnet 4.5 (Thinking) | 334 | Anthropic (proxied) |
| Claude Opus 4.5 (Thinking) | 1012 | Anthropic (proxied) |
| GPT-OSS 120B (Medium) | 342 | OpenAI (proxied) |

Models are dynamic — the list changes as Google adds/removes them. The plugin reads labels from the response, not a hardcoded list.

Interestingly, non-Google models (Claude, GPT-OSS) are proxied through Codeium/Windsurf infrastructure — Antigravity uses the same language server binary as Windsurf. The `GetUserStatus` response also includes `monthlyPromptCredits`, `monthlyFlowCredits`, and `monthlyFlexCreditPurchaseAmount` fields inherited from the Windsurf credit system, but these appear to be completely irrelevant to Antigravity's quota model which is purely fraction-based per model.

## Plugin Strategy

1. Discover LS process via `ctx.host.ls.discover()` (ps + lsof)
2. Probe ports with `GetUnleashData` to find the Connect-RPC endpoint
3. Call `GetUserStatus` for plan name + per-model quota
4. Fall back to `GetCommandModelConfigs` if `GetUserStatus` fails
5. If LS not running: error "Start Antigravity and try again."
