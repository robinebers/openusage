import { vi } from "vitest"

export const makeCtx = () => {
  const files = new Map()

  const ctx = {
    nowIso: "2026-02-02T00:00:00.000Z",
    host: {
      fs: {
        exists: (path) => files.has(path),
        readText: (path) => files.get(path),
        writeText: vi.fn((path, text) => files.set(path, text)),
      },
      keychain: {
        readGenericPassword: vi.fn(),
        writeGenericPassword: vi.fn(),
      },
      sqlite: {
        query: vi.fn(() => "[]"),
        exec: vi.fn(),
      },
      http: {
        request: vi.fn(),
      },
      log: {
        warn: vi.fn(),
        error: vi.fn(),
      },
    },
  }

  ctx.line = {
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
  }

  ctx.fmt = {
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
  }

  const b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  ctx.base64 = {
    decode: (str) => {
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
    },
    encode: (str) => {
      let result = ""
      const len = str.length
      let i = 0
      while (i < len) {
        const chunkStart = i
        const a = str.charCodeAt(i++)
        const b = i < len ? str.charCodeAt(i++) : 0
        const c = i < len ? str.charCodeAt(i++) : 0
        const bytesInChunk = i - chunkStart
        const n = (a << 16) | (b << 8) | c
        result += b64chars.charAt((n >> 18) & 63)
        result += b64chars.charAt((n >> 12) & 63)
        result += bytesInChunk < 2 ? "=" : b64chars.charAt((n >> 6) & 63)
        result += bytesInChunk < 3 ? "=" : b64chars.charAt(n & 63)
      }
      return result
    },
  }

  ctx.jwt = {
    decodePayload: (token) => {
      try {
        const parts = token.split(".")
        if (parts.length !== 3) return null
        const decoded = ctx.base64.decode(parts[1])
        return JSON.parse(decoded)
      } catch (e) {
        return null
      }
    },
  }

  ctx.util = {
    tryParseJson: (text) => {
      if (text === null || text === undefined) return null
      const trimmed = String(text).trim()
      if (!trimmed) return null
      try {
        return JSON.parse(trimmed)
      } catch (e) {
        return null
      }
    },
    safeJsonParse: (text) => {
      if (text === null || text === undefined) return { ok: false }
      const trimmed = String(text).trim()
      if (!trimmed) return { ok: false }
      try {
        return { ok: true, value: JSON.parse(trimmed) }
      } catch (e) {
        return { ok: false }
      }
    },
    request: (opts) => ctx.host.http.request(opts),
    requestJson: (opts) => {
      const resp = ctx.util.request(opts)
      const parsed = ctx.util.safeJsonParse(resp.bodyText)
      return { resp, json: parsed.ok ? parsed.value : null }
    },
    isAuthStatus: (status) => status === 401 || status === 403,
    retryOnceOnAuth: (opts) => {
      let resp = opts.request()
      if (ctx.util.isAuthStatus(resp.status)) {
        const token = opts.refresh()
        if (token) {
          resp = opts.request(token)
        }
      }
      return resp
    },
    parseDateMs: (value) => {
      if (value instanceof Date) {
        const dateMs = value.getTime()
        return Number.isFinite(dateMs) ? dateMs : null
      }
      if (typeof value === "number") {
        return Number.isFinite(value) ? value : null
      }
      if (typeof value === "string") {
        const parsed = Date.parse(value)
        if (Number.isFinite(parsed)) return parsed
        const n = Number(value)
        return Number.isFinite(n) ? n : null
      }
      return null
    },
    needsRefreshByExpiry: (opts) => {
      if (!opts) return true
      if (opts.expiresAtMs === null || opts.expiresAtMs === undefined) return true
      const nowMs = Number(opts.nowMs)
      const expiresAtMs = Number(opts.expiresAtMs)
      let bufferMs = Number(opts.bufferMs)
      if (!Number.isFinite(nowMs)) return true
      if (!Number.isFinite(expiresAtMs)) return true
      if (!Number.isFinite(bufferMs)) bufferMs = 0
      return nowMs + bufferMs >= expiresAtMs
    },
  }

  return ctx
}
