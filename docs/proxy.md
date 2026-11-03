# Proxy

OpenUsage can send its provider requests through a proxy.

- Types: `socks5://`, `http://`, `https://`
- Config file: `~/.openusage/config.json`
- Default: off, so requests follow the macOS system proxy settings
- UI: none

```json
{
  "proxy": {
    "enabled": true,
    "url": "socks5://127.0.0.1:10808"
  }
}
```

- Default ports: 1080 for `socks5`, 80 for `http`, 443 for `https`. With `https`, the connection to
  the proxy uses TLS.
- For a proxy sign-in, put it in the URL: `http://user:pass@proxy.example.com:8080`. Percent-encode an
  `@` or `:` inside the user name or password. Any app you run can read the file.
- OpenUsage reads the file once per launch. Quit and reopen it after a change.
- It logs `proxy on` with the scheme, host, and port, or a `proxy off` error that says what to fix.
  An unreadable file leaves proxying off. Neither line shows the password. See
  [Debugging](debugging.md):

  ```sh
  log show --last 1h --predicate 'subsystem == "OpenUsage" AND category == "config"'
  ```

## What goes through the proxy

Every provider request, sign-in token exchanges included, and requests to a
[CLIProxyAPI hub](cliproxyapi.md). These don't:

- The sign-in page and its `localhost` callback, which use your browser's proxy settings.
- [Update](updates.md) checks and the telemetry in [Privacy](privacy.md), which follow the macOS system
  proxy settings.
