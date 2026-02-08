(function () {
  const SETTINGS_PATH = "~/.gemini/settings.json"
  const OAUTH_CREDS_PATH = "~/.gemini/oauth_creds.json"
  const QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
  const LOAD_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
  const PROJECTS_URL = "https://cloudresourcemanager.googleapis.com/v1/projects"
  const TOKEN_URL = "https://oauth2.googleapis.com/token"
  const REFRESH_BUFFER_MS = 5 * 60 * 1000
  const IDE_METADATA = { ideType: "GEMINI_CLI", pluginType: "GEMINI" }
  const OAUTH2_JS_RELATIVE_PATHS = "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js".split("|")
  const OAUTH2_JS_CANDIDATES = "~/.bun/install/global/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|~/.bun/install/global/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|~/.npm-global/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|~/.npm-global/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|~/AppData/Roaming/npm/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|~/AppData/Roaming/npm/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|/usr/local/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|~/.linuxbrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js|/home/linuxbrew/.linuxbrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js".split("|")
  function joinPath(base, leaf) {
    return String(base || "").replace(/[\\/]+$/, "") + "/" + String(leaf || "").replace(/^[\\/]+/, "")
  }
  function dirnamePath(path) {
    const normalized = String(path || "").replace(/\\/g, "/")
    const idx = normalized.lastIndexOf("/")
    if (idx <= 0) return null
    return normalized.slice(0, idx)
  }
  function readJson(ctx, path) {
    if (!ctx.host.fs.exists(path)) return null
    try {
      const parsed = ctx.util.tryParseJson(ctx.host.fs.readText(path))
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      ctx.host.log.warn("failed to parse json at " + path + ": " + String(e))
      return null
    }
  }
  function readAuthType(settings) {
    if (!settings || typeof settings !== "object") return null
    const direct = settings.authType
    if (typeof direct === "string" && direct.trim()) return direct.trim().toLowerCase()
    const nested =
      (settings.auth && settings.auth.type) ||
      (settings.authentication && settings.authentication.type) ||
      (settings.login && settings.login.type)
    if (typeof nested === "string" && nested.trim()) return nested.trim().toLowerCase()
    return null
  }
  function assertSupportedAuthType(ctx) {
    const settings = readJson(ctx, SETTINGS_PATH)
    const authType = readAuthType(settings)
    if (!authType || authType === "oauth-personal") return
    if (authType === "api-key") {
      throw "Gemini usage unavailable for api-key auth. Use OAuth sign-in in Gemini CLI."
    }
    if (authType === "vertex-ai") {
      throw "Gemini usage unavailable for vertex-ai auth. Use OAuth sign-in in Gemini CLI."
    }
    throw "Gemini usage unavailable for unsupported auth type: " + authType + ". Use OAuth sign-in in Gemini CLI."
  }
  function decodeIdToken(ctx, idToken) {
    if (!idToken) return null
    return ctx.jwt.decodePayload(idToken) || null
  }
  function loadOauthCreds(ctx) {
    const creds = readJson(ctx, OAUTH_CREDS_PATH)
    if (!creds || !creds.access_token || !creds.id_token) return null
    return creds
  }
  function saveOauthCreds(ctx, creds) {
    try {
      ctx.host.fs.writeText(OAUTH_CREDS_PATH, JSON.stringify(creds, null, 2))
    } catch (e) {
      ctx.host.log.warn("failed to write oauth_creds.json: " + String(e))
    }
  }
  function tokenExpiresAtMs(ctx, creds) {
    const expiry = creds && creds.expiry_date
    const parsed = ctx.util.parseDateMs(expiry)
    return typeof parsed === "number" ? parsed : null
  }
  function needsRefresh(ctx, creds) {
    return ctx.util.needsRefreshByExpiry({
      nowMs: Date.now(),
      expiresAtMs: tokenExpiresAtMs(ctx, creds),
      bufferMs: REFRESH_BUFFER_MS,
    })
  }
  function buildOauth2PathCandidates(ctx) {
    const out = OAUTH2_JS_CANDIDATES.slice()
    let explicit = null
    try {
      explicit = ctx.host.env.get("GEMINI_OAUTH2_JS_PATH")
    } catch {}
    if (typeof explicit === "string" && explicit.trim()) {
      out.unshift(explicit.trim())
    }
    let geminiCliPath = null
    try {
      geminiCliPath = ctx.host.env.get("GEMINI_CLI_PATH")
    } catch {}
    if (typeof geminiCliPath === "string" && geminiCliPath.trim()) {
      const binPath = geminiCliPath.trim()
      const binDir = dirnamePath(binPath)
      const rootDir = binDir ? dirnamePath(binDir) : null
      if (rootDir) {
        for (let i = 0; i < OAUTH2_JS_RELATIVE_PATHS.length; i += 1) {
          out.unshift(joinPath(rootDir, OAUTH2_JS_RELATIVE_PATHS[i]))
        }
      }
    }
    return out
  }
  function extractOauthClient(ctx) {
    const candidates = buildOauth2PathCandidates(ctx)
    for (let i = 0; i < candidates.length; i += 1) {
      const path = candidates[i]
      if (!ctx.host.fs.exists(path)) continue
      let text
      try {
        text = ctx.host.fs.readText(path)
      } catch {
        continue
      }
      if (!text) continue
      const idMatch = text.match(/OAUTH_CLIENT_ID\s*=\s*["'`]([^"'`]+)["'`]/)
      const secretMatch = text.match(/OAUTH_CLIENT_SECRET\s*=\s*["'`]([^"'`]+)["'`]/)
      if (!idMatch || !secretMatch) continue
      return { clientId: idMatch[1], clientSecret: secretMatch[1] }
    }
    return null
  }
  function refreshToken(ctx, creds) {
    if (!creds.refresh_token) {
      throw "Gemini session expired. Run `gemini auth login` to authenticate."
    }
    const oauthClient = extractOauthClient(ctx)
    if (!oauthClient) {
      throw "Gemini OAuth client not found. Reinstall Gemini CLI and try again."
    }
    let resp
    try {
      resp = ctx.util.request({
        method: "POST",
        url: TOKEN_URL,
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "application/json",
        },
        bodyText:
          "client_id=" +
          encodeURIComponent(oauthClient.clientId) +
          "&client_secret=" +
          encodeURIComponent(oauthClient.clientSecret) +
          "&refresh_token=" +
          encodeURIComponent(creds.refresh_token) +
          "&grant_type=refresh_token",
        timeoutMs: 15000,
      })
    } catch (e) {
      ctx.host.log.error("gemini token refresh request failed: " + String(e))
      return null
    }
    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Gemini session expired. Run `gemini auth login` to authenticate."
    }
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("gemini token refresh returned status " + resp.status)
      return null
    }
    const body = ctx.util.tryParseJson(resp.bodyText)
    if (!body || !body.access_token) return null
    creds.access_token = body.access_token
    if (body.refresh_token) creds.refresh_token = body.refresh_token
    if (body.id_token) creds.id_token = body.id_token
    if (typeof body.expires_in === "number") {
      creds.expiry_date = Date.now() + body.expires_in * 1000
    }
    saveOauthCreds(ctx, creds)
    return creds.access_token
  }
  function postJson(ctx, url, accessToken, body) {
    return ctx.util.request({
      method: "POST",
      url,
      headers: {
        Authorization: "Bearer " + accessToken,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      bodyText: JSON.stringify(body || {}),
      timeoutMs: 10000,
    })
  }
  function readFirstStringDeep(obj, keys) {
    if (!obj || typeof obj !== "object") return null
    for (let i = 0; i < keys.length; i += 1) {
      const value = obj[keys[i]]
      if (typeof value === "string" && value.trim()) return value.trim()
    }
    if (Array.isArray(obj)) {
      for (let i = 0; i < obj.length; i += 1) {
        const found = readFirstStringDeep(obj[i], keys)
        if (found) return found
      }
      return null
    }
    const values = Object.values(obj)
    for (let i = 0; i < values.length; i += 1) {
      const found = readFirstStringDeep(values[i], keys)
      if (found) return found
    }
    return null
  }
  function mapTierToPlan(tier, idTokenPayload) {
    if (!tier) return null
    const normalized = String(tier).trim().toLowerCase()
    if (normalized === "standard-tier") return "Paid"
    if (normalized === "legacy-tier") return "Legacy"
    if (normalized === "free-tier") {
      return idTokenPayload && idTokenPayload.hd ? "Workspace" : "Free"
    }
    return null
  }
  function discoverProjectId(ctx, accessToken, loadCodeAssistData) {
    const fromLoadCodeAssist = readFirstStringDeep(loadCodeAssistData, ["cloudaicompanionProject"])
    if (fromLoadCodeAssist) return fromLoadCodeAssist
    let projectsResp
    try {
      projectsResp = ctx.util.request({
        method: "GET",
        url: PROJECTS_URL,
        headers: { Authorization: "Bearer " + accessToken, Accept: "application/json" },
        timeoutMs: 10000,
      })
    } catch (e) {
      ctx.host.log.warn("project discovery failed: " + String(e))
      return null
    }
    if (projectsResp.status < 200 || projectsResp.status >= 300) return null
    const projectsData = ctx.util.tryParseJson(projectsResp.bodyText)
    const projects = projectsData && Array.isArray(projectsData.projects) ? projectsData.projects : []
    if (!projects.length) return null
    for (let i = 0; i < projects.length; i += 1) {
      const project = projects[i]
      const projectId = project && typeof project.projectId === "string" ? project.projectId : null
      if (!projectId) continue
      if (projectId.indexOf("gen-lang-client") === 0) return projectId
      const labels = project && project.labels && typeof project.labels === "object" ? project.labels : null
      if (labels && labels["generative-language"] !== undefined) return projectId
    }
    return null
  }
  function collectQuotaBuckets(value, out) {
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i += 1) collectQuotaBuckets(value[i], out)
      return
    }
    if (!value || typeof value !== "object") return
    if (typeof value.remainingFraction === "number") {
      const modelId =
        typeof value.modelId === "string"
          ? value.modelId
          : typeof value.model_id === "string"
            ? value.model_id
            : null
      out.push({
        modelId: modelId || "unknown",
        remainingFraction: value.remainingFraction,
        resetTime: value.resetTime || value.reset_time || null,
      })
    }
    const nested = Object.values(value)
    for (let i = 0; i < nested.length; i += 1) {
      collectQuotaBuckets(nested[i], out)
    }
  }
  function toUsageLine(ctx, label, bucket) {
    const clampedRemaining = Math.max(0, Math.min(1, Number(bucket.remainingFraction)))
    const used = Math.round((1 - clampedRemaining) * 100)
    const resetsAt = ctx.util.toIso(bucket.resetTime)
    return ctx.line.progress({
      label,
      used,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: resetsAt || undefined,
    })
  }
  function pickLowestRemainingBucket(buckets) {
    if (!buckets.length) return null
    let best = null
    for (let i = 0; i < buckets.length; i += 1) {
      const bucket = buckets[i]
      if (!Number.isFinite(bucket.remainingFraction)) continue
      if (!best || bucket.remainingFraction < best.remainingFraction) {
        best = bucket
      }
    }
    return best
  }
  function parseQuotaLines(ctx, quotaData) {
    const buckets = []
    collectQuotaBuckets(quotaData, buckets)
    if (!buckets.length) return []
    const byModel = {}
    for (let i = 0; i < buckets.length; i += 1) {
      const bucket = buckets[i]
      const modelId = String(bucket.modelId || "").replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim()
      if (!modelId) continue
      if (!byModel[modelId] || bucket.remainingFraction < byModel[modelId].remainingFraction) {
        byModel[modelId] = bucket
      }
    }
    const allBuckets = Object.values(byModel)
    const proBuckets = []
    const flashBuckets = []
    for (let i = 0; i < allBuckets.length; i += 1) {
      const bucket = allBuckets[i]
      const lower = String(bucket.modelId || "").toLowerCase()
      if (lower.indexOf("gemini") !== -1 && lower.indexOf("pro") !== -1) {
        proBuckets.push(bucket)
      } else if (lower.indexOf("gemini") !== -1 && lower.indexOf("flash") !== -1) {
        flashBuckets.push(bucket)
      }
    }
    const lines = []
    const pro = pickLowestRemainingBucket(proBuckets)
    if (pro) lines.push(toUsageLine(ctx, "Pro", pro))
    const flash = pickLowestRemainingBucket(flashBuckets)
    if (flash) lines.push(toUsageLine(ctx, "Flash", flash))
    return lines
  }
  function fetchLoadCodeAssist(ctx, accessToken, creds) {
    let currentToken = accessToken
    const resp = ctx.util.retryOnceOnAuth({
      request: function (token) {
        return postJson(ctx, LOAD_CODE_ASSIST_URL, token || currentToken, { metadata: IDE_METADATA })
      },
      refresh: function () {
        const refreshed = refreshToken(ctx, creds)
        if (refreshed) currentToken = refreshed
        return refreshed
      },
    })
    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Gemini session expired. Run `gemini auth login` to authenticate."
    }
    if (resp.status < 200 || resp.status >= 300) {
      return { data: null, accessToken: currentToken }
    }
    return { data: ctx.util.tryParseJson(resp.bodyText), accessToken: currentToken }
  }
  function fetchQuotaWithRetry(ctx, accessToken, creds, projectId) {
    let currentToken = accessToken
    let didRefresh = false
    const resp = ctx.util.retryOnceOnAuth({
      request: function (token) {
        const body = projectId ? { project: projectId } : {}
        return postJson(ctx, QUOTA_URL, token || currentToken, body)
      },
      refresh: function () {
        didRefresh = true
        const refreshed = refreshToken(ctx, creds)
        if (refreshed) currentToken = refreshed
        return refreshed
      },
    })
    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Gemini session expired. Run `gemini auth login` to authenticate."
    }
    if (resp.status < 200 || resp.status >= 300) {
      if (didRefresh) {
        throw "Gemini quota request failed after refresh. Try again."
      }
      throw "Gemini quota request failed (HTTP " + String(resp.status) + "). Try again later."
    }
    return resp
  }
  function probe(ctx) {
    assertSupportedAuthType(ctx)
    const creds = loadOauthCreds(ctx)
    if (!creds) {
      throw "Not logged in. Run `gemini auth login` to authenticate."
    }
    let accessToken = creds.access_token
    if (needsRefresh(ctx, creds)) {
      const refreshed = refreshToken(ctx, creds)
      if (refreshed) accessToken = refreshed
      else if (!accessToken) throw "Not logged in. Run `gemini auth login` to authenticate."
    }
    const idTokenPayload = decodeIdToken(ctx, creds.id_token)
    const loadCodeAssistResult = fetchLoadCodeAssist(ctx, accessToken, creds)
    accessToken = loadCodeAssistResult.accessToken
    const loadCodeAssistData = loadCodeAssistResult.data
    const tier = readFirstStringDeep(loadCodeAssistData, ["tier", "userTier", "subscriptionTier"])
    const plan = mapTierToPlan(tier, idTokenPayload)
    const projectId = discoverProjectId(ctx, accessToken, loadCodeAssistData)
    const quotaResp = fetchQuotaWithRetry(ctx, accessToken, creds, projectId)
    const quotaData = ctx.util.tryParseJson(quotaResp.bodyText)
    if (!quotaData || typeof quotaData !== "object") {
      throw "Gemini quota response invalid. Try again later."
    }
    const lines = parseQuotaLines(ctx, quotaData)
    const email = idTokenPayload && typeof idTokenPayload.email === "string" ? idTokenPayload.email : null
    if (email) {
      lines.push(ctx.line.text({ label: "Account", value: email }))
    }
    if (!lines.length) {
      lines.push(ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }))
    }
    return { plan: plan || undefined, lines }
  }
  globalThis.__openusage_plugin = { id: "gemini", probe }
})()
