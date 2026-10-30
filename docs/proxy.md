# Proxy

OpenUsage can send its provider requests through a proxy that you set in `~/.openusage/config.json`.
The app has no setting for it.

## The file

```json
{
  "proxy": {
    "enabled": true,
    "url": "socks5://127.0.0.1:10808"
  }
}
```

`url` takes a `socks5://`, `http://`, or `https://` proxy. Without a port, the scheme's default
applies: 1080 for `socks5`, 80 for `http`, and 443 for `https`. With `https`, the connection to the
proxy itself uses TLS.

A proxy that needs a sign-in takes the user name and password in the URL. Percent-encode an `@` or a
`:` inside either one.

```json
{
  "proxy": {
    "enabled": true,
    "url": "http://user:pass@proxy.example.com:8080"
  }
}
```

The file is plain text, so any app you run can read the password in it.

## How OpenUsage reads it

- OpenUsage reads the file once, before its first provider request after launch. Quit and reopen
  OpenUsage after you change the file.
- With no file, no `proxy` key, or `"enabled": false`, requests follow the macOS system proxy
  settings.
- With the proxy on, OpenUsage logs `proxy on` with the scheme, host, and port.
- If OpenUsage cannot read or parse the file, it logs a `proxy off` error that says what to fix, and
  requests follow the macOS system proxy settings. Neither line shows the user name or the password.

Both lines are in the `config` category, and macOS keeps them on disk, so `log show` finds them later:

```sh
log show --last 1h --predicate 'subsystem == "OpenUsage" AND category == "config"'
```

[Debugging](debugging.md) has more on reading the log.

## What goes through the proxy

Every request OpenUsage sends to a provider goes through the proxy: usage reads, token renewals, and
the token exchanges and device-code checks during sign-in.

These do not:

- The sign-in page, which opens in your browser and follows the browser's proxy settings.
- The sign-in callback, which your browser sends to OpenUsage on `localhost`.
- [Update](updates.md) checks and downloads, and the anonymous telemetry and crash reports described
  in [Privacy](privacy.md). They follow the macOS system proxy settings.
