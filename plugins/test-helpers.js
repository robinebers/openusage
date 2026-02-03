/**
 * Shared test helpers for plugin tests.
 * Provides a common context factory that matches the plugin runtime context API.
 */

function b64decode(str) {
  const b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  str = str.replace(/-/g, "+").replace(/_/g, "/")
  while (str.length % 4) str += "="
  str = str.replace(/=+$/, "")
  let result = ""
  const len = str.length
  let i = 0
  while (i < len) {
    const remaining = len - i
    const a = b64chars.indexOf(str.charAt(i++))
    const b = b64chars.indexOf(str.charAt(i++))
    const c = remaining > 2 ? b64chars.indexOf(str.charAt(i++)) : 0
    const d = remaining > 3 ? b64chars.indexOf(str.charAt(i++)) : 0
    const n = (a << 18) | (b << 12) | (c << 6) | d
    result += String.fromCharCode((n >> 16) & 0xff)
    if (remaining > 2) result += String.fromCharCode((n >> 8) & 0xff)
    if (remaining > 3) result += String.fromCharCode(n & 0xff)
  }
  return result
}

export function makePluginTestContext(overrides = {}, vi = null) {
  const files = new Map()
  
  return {
    nowIso: "2026-02-02T00:00:00.000Z",
    app: {
      pluginDataDir: "/tmp/mock",
      appDataDir: "/tmp/app",
    },
    host: {
      fs: {
        exists: (path) => files.has(path),
        readText: (path) => {
          const value = files.get(path)
          if (value === undefined && !overrides.host?.fs?.readText) {
            throw new Error("missing")
          }
          return overrides.host?.fs?.readText?.(path) ?? files.get(path)
        },
        writeText: overrides.host?.fs?.writeText ?? (vi ? vi.fn((path, text) => files.set(path, text)) : ((path, text) => files.set(path, text))),
      },
      keychain: {
        readGenericPassword: overrides.host?.keychain?.readGenericPassword ?? (vi ? vi.fn() : (() => null)),
        writeGenericPassword: overrides.host?.keychain?.writeGenericPassword ?? (vi ? vi.fn() : (() => {})),
      },
      http: {
        request: overrides.host?.http?.request ?? (vi ? vi.fn() : (() => ({}))),
      },
      sqlite: {
        query: overrides.host?.sqlite?.query ?? (vi ? vi.fn(() => JSON.stringify([])) : (() => JSON.stringify([]))),
        exec: overrides.host?.sqlite?.exec ?? (vi ? vi.fn() : (() => {})),
      },
      log: {
        error: overrides.host?.log?.error ?? (vi ? vi.fn() : (() => {})),
        warn: overrides.host?.log?.warn ?? (vi ? vi.fn() : (() => {})),
      },
    },
    line: {
      text: (opts) => {
        const line = { type: "text", label: opts.label, value: opts.value }
        if (opts.color) line.color = opts.color
        if (opts.subtitle) line.subtitle = opts.subtitle
        return line
      },
      progress: (opts) => {
        const line = { type: "progress", label: opts.label, value: opts.value, max: opts.max }
        if (opts.unit) line.unit = opts.unit
        if (opts.color) line.color = opts.color
        if (opts.subtitle) line.subtitle = opts.subtitle
        return line
      },
      badge: (opts) => {
        const line = { type: "badge", label: opts.label, text: opts.text }
        if (opts.color) line.color = opts.color
        if (opts.subtitle) line.subtitle = opts.subtitle
        return line
      },
    },
    fmt: {
      planLabel: (value) => {
        const text = String(value || "").trim()
        if (!text) return ""
        return text.replace(/(^|\s)([a-z])/g, (match, space, letter) => space + letter.toUpperCase())
      },
      resetIn: (secondsUntil) => {
        if (!Number.isFinite(secondsUntil) || secondsUntil < 0) return null
        const totalMinutes = Math.floor(secondsUntil / 60)
        const totalHours = Math.floor(totalMinutes / 60)
        const days = Math.floor(totalHours / 24)
        const hours = totalHours % 24
        const minutes = totalMinutes % 60
        if (days > 0) return `${days}d ${hours}h`
        if (totalHours > 0) return `${totalHours}h ${minutes}m`
        if (totalMinutes > 0) return `${totalMinutes}m`
        return "<1m"
      },
      dollars: (cents) => Math.round((cents / 100) * 100) / 100,
      date: (unixMs) => {
        const d = new Date(Number(unixMs))
        const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return months[d.getMonth()] + " " + String(d.getDate())
      },
    },
    base64: overrides.base64 ?? { decode: b64decode },
    jwt: overrides.jwt ?? {
      decodePayload: (token) => {
        try {
          const parts = token.split(".")
          if (parts.length !== 3) return null
          const decoded = b64decode(parts[1])
          return JSON.parse(decoded)
        } catch (e) {
          return null
        }
      },
    },
    ...overrides,
  }
}
