(function () {
  const CRED_FILE = "~/.claude/.credentials.json"
  const KEYCHAIN_SERVICE = "Claude Code-credentials"
  const USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
  const REFRESH_URL = "https://platform.claude.com/v1/oauth/token"
  const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  const SCOPES = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
  const REFRESH_BUFFER_MS = 5 * 60 * 1000 // refresh 5 minutes before expiration

  function utf8DecodeBytes(bytes) {
    // Prefer native TextDecoder when available (QuickJS may not expose it).
    if (typeof TextDecoder !== "undefined") {
      try {
        return new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(bytes))
      } catch {}
    }

    // Minimal UTF-8 decoder (replacement char on invalid sequences).
    let out = ""
    for (let i = 0; i < bytes.length; ) {
      const b0 = bytes[i] & 0xff
      if (b0 < 0x80) {
        out += String.fromCharCode(b0)
        i += 1
        continue
      }

      // 2-byte
      if (b0 >= 0xc2 && b0 <= 0xdf) {
        if (i + 1 >= bytes.length) {
          out += "\ufffd"
          break
        }
        const b1 = bytes[i + 1] & 0xff
        if ((b1 & 0xc0) !== 0x80) {
          out += "\ufffd"
          i += 1
          continue
        }
        const cp = ((b0 & 0x1f) << 6) | (b1 & 0x3f)
        out += String.fromCharCode(cp)
        i += 2
        continue
      }

      // 3-byte
      if (b0 >= 0xe0 && b0 <= 0xef) {
        if (i + 2 >= bytes.length) {
          out += "\ufffd"
          break
        }
        const b1 = bytes[i + 1] & 0xff
        const b2 = bytes[i + 2] & 0xff
        const validCont = (b1 & 0xc0) === 0x80 && (b2 & 0xc0) === 0x80
        const notOverlong = !(b0 === 0xe0 && b1 < 0xa0)
        const notSurrogate = !(b0 === 0xed && b1 >= 0xa0)
        if (!validCont || !notOverlong || !notSurrogate) {
          out += "\ufffd"
          i += 1
          continue
        }
        const cp = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f)
        out += String.fromCharCode(cp)
        i += 3
        continue
      }

      // 4-byte
      if (b0 >= 0xf0 && b0 <= 0xf4) {
        if (i + 3 >= bytes.length) {
          out += "\ufffd"
          break
        }
        const b1 = bytes[i + 1] & 0xff
        const b2 = bytes[i + 2] & 0xff
        const b3 = bytes[i + 3] & 0xff
        const validCont = (b1 & 0xc0) === 0x80 && (b2 & 0xc0) === 0x80 && (b3 & 0xc0) === 0x80
        const notOverlong = !(b0 === 0xf0 && b1 < 0x90)
        const notTooHigh = !(b0 === 0xf4 && b1 > 0x8f)
        if (!validCont || !notOverlong || !notTooHigh) {
          out += "\ufffd"
          i += 1
          continue
        }
        const cp =
          ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f)
        const n = cp - 0x10000
        out += String.fromCharCode(0xd800 + ((n >> 10) & 0x3ff), 0xdc00 + (n & 0x3ff))
        i += 4
        continue
      }

      out += "\ufffd"
      i += 1
    }
    return out
  }

  function tryParseCredentialJSON(ctx, text) {
    if (!text) return null
    const parsed = ctx.util.tryParseJson(text)
    if (parsed) return parsed

    // Some macOS keychain items are returned by `security ... -w` as hex-encoded UTF-8 bytes.
    // Example prefix: "7b0a" ( "{\\n" ).
    // Support both plain hex and "0x..." forms.
    let hex = String(text).trim()
    if (hex.startsWith("0x") || hex.startsWith("0X")) hex = hex.slice(2)
    if (!hex || hex.length % 2 !== 0) return null
    if (!/^[0-9a-fA-F]+$/.test(hex)) return null
    try {
      const bytes = []
      for (let i = 0; i < hex.length; i += 2) {
        bytes.push(parseInt(hex.slice(i, i + 2), 16))
      }
      const decoded = utf8DecodeBytes(bytes)
      const decodedParsed = ctx.util.tryParseJson(decoded)
      if (decodedParsed) return decodedParsed
    } catch {}

    return null
  }

  function loadCredentials(ctx) {
    // Try file first
    if (ctx.host.fs.exists(CRED_FILE)) {
      try {
        const text = ctx.host.fs.readText(CRED_FILE)
        const parsed = tryParseCredentialJSON(ctx, text)
        if (parsed) {
          const oauth = parsed.claudeAiOauth
          if (oauth && oauth.accessToken) {
            ctx.host.log.info("credentials loaded from file")
            return { oauth, source: "file", fullData: parsed }
          }
        }
        ctx.host.log.warn("credentials file exists but no valid oauth data")
      } catch (e) {
        ctx.host.log.warn("credentials file read failed: " + String(e))
      }
    }

    // Try keychain fallback
    try {
      const keychainValue = ctx.host.keychain.readGenericPassword(KEYCHAIN_SERVICE)
      if (keychainValue) {
        const parsed = tryParseCredentialJSON(ctx, keychainValue)
        if (parsed) {
          const oauth = parsed.claudeAiOauth
          if (oauth && oauth.accessToken) {
            ctx.host.log.info("credentials loaded from keychain")
            return { oauth, source: "keychain", fullData: parsed }
          }
        }
        ctx.host.log.warn("keychain has data but no valid oauth")
      }
    } catch (e) {
      ctx.host.log.info("keychain read failed (may not exist): " + String(e))
    }

    ctx.host.log.warn("no credentials found")
    return null
  }

  function saveCredentials(ctx, source, fullData) {
    // MUST use minified JSON - macOS `security -w` hex-encodes values with newlines,
    // which Claude Code can't read back, causing it to invalidate the session.
    const text = JSON.stringify(fullData)
    if (source === "file") {
      try {
        ctx.host.fs.writeText(CRED_FILE, text)
      } catch (e) {
        ctx.host.log.error("Failed to write Claude credentials file: " + String(e))
      }
    } else if (source === "keychain") {
      try {
        ctx.host.keychain.writeGenericPassword(KEYCHAIN_SERVICE, text)
      } catch (e) {
        ctx.host.log.error("Failed to write Claude credentials keychain: " + String(e))
      }
    }
  }

  function needsRefresh(ctx, oauth, nowMs) {
    return ctx.util.needsRefreshByExpiry({
      nowMs,
      expiresAtMs: oauth.expiresAt,
      bufferMs: REFRESH_BUFFER_MS,
    })
  }

  function refreshToken(ctx, creds) {
    const { oauth, source, fullData } = creds
    if (!oauth.refreshToken) {
      ctx.host.log.warn("refresh skipped: no refresh token")
      return null
    }

    ctx.host.log.info("attempting token refresh")
    try {
      const resp = ctx.util.request({
        method: "POST",
        url: REFRESH_URL,
        headers: { "Content-Type": "application/json" },
        bodyText: JSON.stringify({
          grant_type: "refresh_token",
          refresh_token: oauth.refreshToken,
          client_id: CLIENT_ID,
          scope: SCOPES,
        }),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        let errorCode = null
        const body = ctx.util.tryParseJson(resp.bodyText)
        if (body) errorCode = body.error || body.error_description
        ctx.host.log.error("refresh failed: status=" + resp.status + " error=" + String(errorCode))
        if (errorCode === "invalid_grant") {
          throw "Session expired. Run `claude` to log in again."
        }
        throw "Token expired. Run `claude` to log in again."
      }
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("refresh returned unexpected status: " + resp.status)
        return null
      }

      const body = ctx.util.tryParseJson(resp.bodyText)
      if (!body) {
        ctx.host.log.warn("refresh response not valid JSON")
        return null
      }
      const newAccessToken = body.access_token
      if (!newAccessToken) {
        ctx.host.log.warn("refresh response missing access_token")
        return null
      }

      // Update oauth credentials
      oauth.accessToken = newAccessToken
      if (body.refresh_token) oauth.refreshToken = body.refresh_token
      if (typeof body.expires_in === "number") {
        oauth.expiresAt = Date.now() + body.expires_in * 1000
      }

      // Persist updated credentials
      fullData.claudeAiOauth = oauth
      saveCredentials(ctx, source, fullData)

      ctx.host.log.info("refresh succeeded, new token expires in " + (body.expires_in || "unknown") + "s")
      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("refresh exception: " + String(e))
      return null
    }
  }

  function fetchUsage(ctx, accessToken) {
    return ctx.util.request({
      method: "GET",
      url: USAGE_URL,
      headers: {
        Authorization: "Bearer " + accessToken.trim(),
        Accept: "application/json",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "OpenUsage",
      },
      timeoutMs: 10000,
    })
  }

  function probe(ctx) {
    const creds = loadCredentials(ctx)
    if (!creds || !creds.oauth || !creds.oauth.accessToken || !creds.oauth.accessToken.trim()) {
      ctx.host.log.error("probe failed: not logged in")
      throw "Not logged in. Run `claude` to authenticate."
    }

    const nowMs = Date.now()
    let accessToken = creds.oauth.accessToken

    // Proactively refresh if token is expired or about to expire
    if (needsRefresh(ctx, creds.oauth, nowMs)) {
      ctx.host.log.info("token needs refresh (expired or expiring soon)")
      const refreshed = refreshToken(ctx, creds)
      if (refreshed) {
        accessToken = refreshed
      } else {
        ctx.host.log.warn("proactive refresh failed, trying with existing token")
      }
    }

    let resp
    let didRefresh = false
    try {
      resp = ctx.util.retryOnceOnAuth({
        request: (token) => {
          try {
            return fetchUsage(ctx, token || accessToken)
          } catch (e) {
            ctx.host.log.error("usage request exception: " + String(e))
            if (didRefresh) {
              throw "Usage request failed after refresh. Try again."
            }
            throw "Usage request failed. Check your connection."
          }
        },
        refresh: () => {
          ctx.host.log.info("usage returned 401, attempting refresh")
          didRefresh = true
          return refreshToken(ctx, creds)
        },
      })
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("usage request failed: " + String(e))
      throw "Usage request failed. Check your connection."
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      ctx.host.log.error("usage returned auth error after all retries: status=" + resp.status)
      throw "Token expired. Run `claude` to log in again."
    }

    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.error("usage returned error: status=" + resp.status)
      throw "Usage request failed (HTTP " + String(resp.status) + "). Try again later."
    }
    
    ctx.host.log.info("usage fetch succeeded")

    let data
    data = ctx.util.tryParseJson(resp.bodyText)
    if (data === null) {
      throw "Usage response invalid. Try again later."
    }

    const lines = []
    let plan = null
    if (creds.oauth.subscriptionType) {
      const planLabel = ctx.fmt.planLabel(creds.oauth.subscriptionType)
      if (planLabel) {
        plan = planLabel
      }
    }

    if (data.five_hour && typeof data.five_hour.utilization === "number") {
      lines.push(ctx.line.progress({
        label: "Session",
        used: data.five_hour.utilization,
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(data.five_hour.resets_at),
        periodDurationMs: 5 * 60 * 60 * 1000 // 5 hours
      }))
    }
    if (data.seven_day && typeof data.seven_day.utilization === "number") {
      lines.push(ctx.line.progress({
        label: "Weekly",
        used: data.seven_day.utilization,
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(data.seven_day.resets_at),
        periodDurationMs: 7 * 24 * 60 * 60 * 1000 // 7 days
      }))
    }
    if (data.seven_day_sonnet && typeof data.seven_day_sonnet.utilization === "number") {
      lines.push(ctx.line.progress({
        label: "Sonnet",
        used: data.seven_day_sonnet.utilization,
        limit: 100,
        format: { kind: "percent" },
        resetsAt: ctx.util.toIso(data.seven_day_sonnet.resets_at),
        periodDurationMs: 7 * 24 * 60 * 60 * 1000 // 7 days
      }))
    }

    if (data.extra_usage && data.extra_usage.is_enabled) {
      const used = data.extra_usage.used_credits
      const limit = data.extra_usage.monthly_limit
      if (typeof used === "number" && typeof limit === "number" && limit > 0) {
        lines.push(ctx.line.progress({
          label: "Extra usage",
          used: ctx.fmt.dollars(used),
          limit: ctx.fmt.dollars(limit),
          format: { kind: "dollars" }
        }))
      } else if (typeof used === "number" && used > 0) {
        lines.push(ctx.line.text({ label: "Extra usage", value: "$" + String(ctx.fmt.dollars(used)) }))
      }
    }

    if (lines.length === 0) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }

    return { plan: plan, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "claude", probe }
})()
