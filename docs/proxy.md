# Proxy Configuration

OpenUsage can route provider and plugin HTTP requests through an optional proxy.

- Supported proxy types: `socks5://`, `http://`, `https://`
- Config file: `~/.openusage/config.json`
- Default: off
- UI: none

## Config File

Create `~/.openusage/config.json`:

```json
{
  "proxy": {
    "enabled": true,
    "url": "socks5://127.0.0.1:10808"
  }
}
```

You can also use an authenticated proxy URL:

```json
{
  "proxy": {
    "enabled": true,
    "url": "http://user:pass@proxy.example.com:8080"
  }
}
```

## Behavior

- Config is loaded once when the app starts.
- Restart OpenUsage after changing the file.
- `localhost`, `127.0.0.1`, and `::1` always bypass the proxy.
- Missing, disabled, invalid, or unreadable config leaves proxying off.
- Proxy credentials are redacted in logs.

## Scope

This applies to provider and plugin HTTP requests that go through OpenUsage's built-in HTTP client.

It is not a general macOS system proxy setting and does not automatically proxy unrelated subprocess network traffic.
