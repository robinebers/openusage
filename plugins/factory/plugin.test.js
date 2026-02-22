import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

// Helper to create a valid JWT with configurable expiry
function makeJwt(expSeconds) {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" }))
  const payload = btoa(JSON.stringify({ exp: expSeconds, org_id: "org_123", email: "test@example.com" }))
  const sig = "signature"
  return `${header}.${payload}.${sig}`
}

describe("factory plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("throws when auth missing", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when auth json is invalid", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.factory/auth.json", "{bad")
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("throws when auth lacks access_token", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({ refresh_token: "refresh" }))
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Invalid auth file")
  })

  it("loads auth from auth.encrypted when auth.json is missing", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.encrypted", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: { orgTotalTokensUsed: 123, totalAllowance: 20000000 },
          premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
  })

  it("loads auth from keychain when auth files are missing", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "Factory Token") {
        return JSON.stringify({
          access_token: makeJwt(futureExp),
          refresh_token: "refresh",
        })
      }
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: { orgTotalTokensUsed: 1, totalAllowance: 20000000 },
          premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("Factory Token")
  })

  it("loads auth from keychain when payload is hex-encoded JSON", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    const payload = JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    })
    const hexPayload = Buffer.from(payload, "utf8").toString("hex")
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "Factory Token") return hexPayload
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: { orgTotalTokensUsed: 9, totalAllowance: 20000000 },
          premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
  })

  it("skips invalid keychain payload and tries next service", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "Factory Token") return "not-json"
      if (service === "Factory token") {
        return JSON.stringify({
          access_token: makeJwt(futureExp),
          refresh_token: "refresh",
        })
      }
      return null
    })
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: { orgTotalTokensUsed: 2, totalAllowance: 20000000 },
          premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("Factory Token")
    expect(ctx.host.keychain.readGenericPassword).toHaveBeenCalledWith("Factory token")
  })

  it("refreshes keychain auth and writes back to keychain", async () => {
    const ctx = makeCtx()
    const nearExp = Math.floor(Date.now() / 1000) + 12 * 60 * 60 // force proactive refresh
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "Factory Token") {
        return JSON.stringify({
          access_token: makeJwt(nearExp),
          refresh_token: "refresh",
        })
      }
      return null
    })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("workos.com")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: makeJwt(futureExp),
            refresh_token: "new-refresh",
          }),
        }
      }
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify({
          usage: {
            startDate: 1770623326000,
            endDate: 1772956800000,
            standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
            premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)
    expect(ctx.host.keychain.writeGenericPassword).toHaveBeenCalledTimes(1)
    const [service, writtenPayload] = ctx.host.keychain.writeGenericPassword.mock.calls[0]
    expect(service).toBe("Factory Token")
    const parsed = JSON.parse(writtenPayload)
    expect(parsed.refresh_token).toBe("new-refresh")
  })

  it("fetches usage and formats standard tokens", async () => {
    const ctx = makeCtx()
    // Token expires in 7 days (no refresh needed)
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: {
            orgTotalTokensUsed: 5000000,
            totalAllowance: 20000000,
          },
          premium: {
            orgTotalTokensUsed: 0,
            totalAllowance: 0,
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Pro")
    const standardLine = result.lines.find((line) => line.label === "Standard")
    expect(standardLine).toBeTruthy()
    expect(standardLine.used).toBe(5000000)
    expect(standardLine.limit).toBe(20000000)
  })

  it("shows premium line when premium allowance > 0", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: {
            orgTotalTokensUsed: 10000000,
            totalAllowance: 200000000,
          },
          premium: {
            orgTotalTokensUsed: 1000000,
            totalAllowance: 50000000,
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Max")
    const premiumLine = result.lines.find((line) => line.label === "Premium")
    expect(premiumLine).toBeTruthy()
    expect(premiumLine.used).toBe(1000000)
    expect(premiumLine.limit).toBe(50000000)
  })

  it("omits premium line when premium allowance is 0", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: {
            orgTotalTokensUsed: 0,
            totalAllowance: 20000000,
          },
          premium: {
            orgTotalTokensUsed: 0,
            totalAllowance: 0,
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const premiumLine = result.lines.find((line) => line.label === "Premium")
    expect(premiumLine).toBeUndefined()
  })

  it("refreshes token when near expiry", async () => {
    const ctx = makeCtx()
    // Token expires in 12 hours (within 24h threshold, needs refresh)
    const nearExp = Math.floor(Date.now() / 1000) + 12 * 60 * 60
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(nearExp),
      refresh_token: "refresh",
    }))

    let refreshCalled = false
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("workos.com")) {
        refreshCalled = true
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: makeJwt(futureExp),
            refresh_token: "new-refresh",
          }),
        }
      }
      // Usage request
      expect(opts.headers.Authorization).toContain("Bearer ")
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify({
          usage: {
            startDate: 1770623326000,
            endDate: 1772956800000,
            standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
            premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    plugin.probe(ctx)

    expect(refreshCalled).toBe(true)
    // Verify auth file was updated
    expect(ctx.host.fs.writeText).toHaveBeenCalled()
  })

  it("falls back to existing token when proactive refresh throws", async () => {
    const ctx = makeCtx()
    const nearExp = Math.floor(Date.now() / 1000) + 12 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(nearExp),
      refresh_token: "refresh",
    }))

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("workos.com")) {
        throw new Error("refresh transport error")
      }
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify({
          usage: {
            startDate: 1770623326000,
            endDate: 1772956800000,
            standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
            premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
  })

  it("throws session expired when refresh fails with 401", async () => {
    const ctx = makeCtx()
    // Token expired
    const pastExp = Math.floor(Date.now() / 1000) - 1000
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(pastExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "{}" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Session expired")
  })

  it("throws on http errors", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({ status: 500, headers: {}, bodyText: "" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("HTTP 500")
  })

  it("throws on invalid usage response", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({ status: 200, headers: {}, bodyText: "bad json" })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response invalid")
  })

  it("throws when usage response missing usage object", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({ status: 200, headers: {}, bodyText: JSON.stringify({}) })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage response missing data")
  })

  it("returns no usage data badge when standard is missing", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines[0].label).toBe("Status")
    expect(result.lines[0].text).toBe("No usage data")
  })

  it("throws on usage request failures", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockImplementation(() => {
      throw new Error("network error")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed")
  })

  it("throws specific error when post-refresh usage request fails", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("workos.com")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: makeJwt(futureExp),
            refresh_token: "new-refresh",
          }),
        }
      }
      usageCalls++
      if (usageCalls === 1) return { status: 401, headers: {}, bodyText: "" }
      throw new Error("network after refresh")
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed after refresh")
  })

  it("throws generic usage request failure when retry helper throws", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.util.retryOnceOnAuth = () => {
      throw new Error("unexpected retry helper error")
    }

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Usage request failed. Check your connection.")
  })

  it("retries on 401 and succeeds after refresh", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("workos.com")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: makeJwt(futureExp),
            refresh_token: "new-refresh",
          }),
        }
      }
      usageCalls++
      if (usageCalls === 1) {
        return { status: 401, headers: {}, bodyText: "" }
      }
      return {
        status: 200,
        headers: {},
        bodyText: JSON.stringify({
          usage: {
            startDate: 1770623326000,
            endDate: 1772956800000,
            standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
            premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
          },
        }),
      }
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(usageCalls).toBe(2)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
  })

  it("throws token expired after retry still fails", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))

    let usageCalls = 0
    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url).includes("workos.com")) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: makeJwt(futureExp),
            refresh_token: "new-refresh",
          }),
        }
      }
      usageCalls++
      return { status: 403, headers: {}, bodyText: "" }
    })

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Token expired")
  })

  it("infers Basic plan from low allowance", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: {
            orgTotalTokensUsed: 0,
            totalAllowance: 1000000,
          },
          premium: {
            orgTotalTokensUsed: 0,
            totalAllowance: 0,
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.plan).toBe("Basic")
  })

  it("includes resetsAt and periodDurationMs from usage dates", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    const startDate = 1770623326000
    const endDate = 1772956800000
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate,
          endDate,
          standard: {
            orgTotalTokensUsed: 0,
            totalAllowance: 20000000,
          },
          premium: {
            orgTotalTokensUsed: 0,
            totalAllowance: 0,
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const standardLine = result.lines.find((line) => line.label === "Standard")
    expect(standardLine.resetsAt).toBeTruthy()
    expect(standardLine.periodDurationMs).toBe(endDate - startDate)
  })

  it("loads direct JWT auth payloads from plain text and quoted JSON strings", async () => {
    const jwt = "header.payload.signature"

    const runCase = async (rawAuth) => {
      const ctx = makeCtx()
      ctx.host.fs.writeText("~/.factory/auth.json", rawAuth)
      ctx.host.http.request.mockReturnValue({
        status: 200,
        headers: {},
        bodyText: JSON.stringify({
          usage: {
            startDate: 1770623326000,
            endDate: 1772956800000,
            standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
            premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
          },
        }),
      })

      delete globalThis.__openusage_plugin
      vi.resetModules()
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
    }

    await runCase(jwt)
    await runCase(JSON.stringify(jwt))
  })

  it("supports uppercase 0X-prefixed hex payload without TextDecoder", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    const payload = JSON.stringify({ access_token: makeJwt(futureExp), refresh_token: "refresh" })
    const hexPayload = "0X" + Buffer.from(payload, "utf8").toString("hex").toUpperCase()
    ctx.host.keychain.readGenericPassword.mockImplementation((service) => {
      if (service === "Factory Token") return hexPayload
      return null
    })
    const originalTextDecoder = globalThis.TextDecoder
    globalThis.TextDecoder = undefined
    try {
      ctx.host.http.request.mockReturnValue({
        status: 200,
        headers: {},
        bodyText: JSON.stringify({
          usage: {
            startDate: 1770623326000,
            endDate: 1772956800000,
            standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
            premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
          },
        }),
      })
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
    } finally {
      globalThis.TextDecoder = originalTextDecoder
    }
  })

  it("throws when keychain API is unavailable and files are missing", async () => {
    const ctx = makeCtx()
    ctx.host.keychain = null
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("continues with existing token when refresh cannot produce a new token", async () => {
    const nearExp = Math.floor(Date.now() / 1000) + 12 * 60 * 60
    const baseAuth = JSON.stringify({
      access_token: makeJwt(nearExp),
      refresh_token: "refresh",
    })

    const runCase = async (refreshResp) => {
      const ctx = makeCtx()
      ctx.host.fs.writeText("~/.factory/auth.json", baseAuth)
      ctx.host.http.request.mockImplementation((opts) => {
        if (String(opts.url).includes("workos.com")) return refreshResp
        return {
          status: 200,
          headers: {},
          bodyText: JSON.stringify({
            usage: {
              startDate: 1770623326000,
              endDate: 1772956800000,
              standard: { orgTotalTokensUsed: 0, totalAllowance: 20000000 },
              premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
            },
          }),
        }
      })

      delete globalThis.__openusage_plugin
      vi.resetModules()
      const plugin = await loadPlugin()
      const result = plugin.probe(ctx)
      expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
    }

    await runCase({ status: 500, headers: {}, bodyText: "" })
    await runCase({ status: 200, headers: {}, bodyText: "not-json" })
    await runCase({ status: 200, headers: {}, bodyText: JSON.stringify({}) })
  })

  it("skips refresh when refresh token is missing and uses existing access token", async () => {
    const ctx = makeCtx()
    const nearExp = Math.floor(Date.now() / 1000) + 12 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(nearExp),
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: 1770623326000,
          endDate: 1772956800000,
          standard: { orgTotalTokensUsed: 1, totalAllowance: 20000000 },
          premium: { orgTotalTokensUsed: 0, totalAllowance: 0 },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines.find((line) => line.label === "Standard")).toBeTruthy()
  })

  it("handles usage dates and counters when optional values are missing", async () => {
    const ctx = makeCtx()
    const futureExp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
    ctx.host.fs.writeText("~/.factory/auth.json", JSON.stringify({
      access_token: makeJwt(futureExp),
      refresh_token: "refresh",
    }))
    ctx.host.http.request.mockReturnValue({
      status: 200,
      headers: {},
      bodyText: JSON.stringify({
        usage: {
          startDate: "n/a",
          endDate: "n/a",
          standard: {
            // Missing orgTotalTokensUsed should fall back to 0
            totalAllowance: 0,
          },
          premium: {
            orgTotalTokensUsed: 0,
            totalAllowance: 0,
          },
        },
      }),
    })

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const standardLine = result.lines.find((line) => line.label === "Standard")
    expect(standardLine).toBeTruthy()
    expect(standardLine.used).toBe(0)
    expect(standardLine.resetsAt).toBeUndefined()
    expect(standardLine.periodDurationMs).toBeUndefined()
    expect(result.plan).toBeNull()
  })
})
