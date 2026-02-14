(function () {
  const SERVICE = "OpenUsage-CLIProxyAPI"

  function loadConfig(ctx) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readGenericPassword !== "function") {
      return null
    }
    try {
      const raw = ctx.host.keychain.readGenericPassword(SERVICE)
      if (!raw) return null
      const parsed = ctx.util.tryParseJson(raw)
      if (!parsed) return null
      const baseUrl = typeof parsed.baseUrl === "string" ? parsed.baseUrl.trim() : ""
      const apiKey = typeof parsed.apiKey === "string" ? parsed.apiKey.trim() : ""
      if (!baseUrl || !apiKey) return null
      return { baseUrl, apiKey }
    } catch {
      return null
    }
  }

  function normalizeBase(baseUrl) {
    let base = String(baseUrl || "").trim()
    base = base.replace(/\/+$/, "")
    base = base.replace(/\/v0\/management$/i, "")
    if (!/^https?:\/\//i.test(base)) {
      base = "http://" + base
    }
    return base.replace(/\/+$/, "")
  }

  function listAuthFiles(ctx, config) {
    const base = normalizeBase(config.baseUrl)
    const response = ctx.util.requestJson({
      method: "GET",
      url: base + "/v0/management/auth-files",
      headers: {
        Authorization: "Bearer " + config.apiKey,
      },
      timeoutMs: 10000,
    })

    if (response.resp.status < 200 || response.resp.status >= 300) {
      throw "Request failed (HTTP " + String(response.resp.status) + ")"
    }

    if (!response.json) return []
    if (Array.isArray(response.json)) return response.json
    if (Array.isArray(response.json.files)) return response.json.files
    return []
  }

  function providerKey(value) {
    if (!value || typeof value !== "string") return "unknown"
    const lower = value.trim().toLowerCase()
    if (!lower) return "unknown"
    if (lower === "anthropic") return "claude"
    return lower
  }

  function summarizeProviders(files) {
    const counts = {}
    for (const file of files) {
      if (!file || typeof file !== "object") continue
      if (file.disabled === true || file.unavailable === true) continue
      const provider = providerKey(file.provider || file.type)
      counts[provider] = (counts[provider] || 0) + 1
    }

    const parts = Object.keys(counts)
      .sort()
      .map((provider) => provider + ": " + counts[provider])

    return parts.length > 0 ? parts.join(" | ") : "none"
  }

  function probe(ctx) {
    const config = loadConfig(ctx)
    if (!config) {
      throw "Not configured. Add CLIProxyAPI URL and key in Settings."
    }

    const files = listAuthFiles(ctx, config)
    const providers = summarizeProviders(files)

    return {
      plan: "Management",
      lines: [
        ctx.line.text({ label: "Status", value: "Connected" }),
        ctx.line.text({ label: "Accounts", value: String(files.length) }),
        ctx.line.text({ label: "Providers", value: providers }),
      ],
    }
  }

  globalThis.__openusage_plugin = { id: "cliproxyapi", probe }
})()
