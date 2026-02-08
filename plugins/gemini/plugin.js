(function () {
  const SETTINGS_PATH = "~/.gemini/settings.json";
  const OAUTH_CREDS_PATH = "~/.gemini/oauth_creds.json";
  const QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";
  const LOAD_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
  const PROJECTS_URL = "https://cloudresourcemanager.googleapis.com/v1/projects";
  const TOKEN_URL = "https://oauth2.googleapis.com/token";
  const REFRESH_BUFFER_MS = 5 * 60 * 1000; // refresh 5 minutes before expiration
  const IDE_METADATA = { ideType: "GEMINI_CLI", pluginType: "GEMINI" };

  // Public OAuth constants from the Gemini CLI source (installed app, not secret).
  // https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts
  const OAUTH_CLIENT_ID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com";
  const OAUTH_CLIENT_SECRET = "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";
  const SESSION_EXPIRED_MSG = "Gemini session expired. Run `gemini auth login` to authenticate.";

  function readJson(ctx, path) {
    try {
      if (!ctx.host.fs.exists(path)) return null;
      const text = ctx.host.fs.readText(path);
      return ctx.util.tryParseJson(text);
    } catch (e) {
      ctx.host.log.warn("readJson failed for " + path + ": " + String(e));
      return null;
    }
  }

  function readAuthType(settings) {
    if (!settings || typeof settings !== "object") return null;
    const value =
      (settings.auth && settings.auth.selectedType) ||
      settings.authType;
    if (typeof value === "string" && value.trim()) return value.trim().toLowerCase();
    return null;
  }

  function assertSupportedAuthType(ctx) {
    const settings = readJson(ctx, SETTINGS_PATH);
    const authType = readAuthType(settings);
    if (!authType || authType === "oauth-personal") return;
    if (authType === "api-key" || authType === "gemini-api-key") {
      throw "Gemini usage unavailable for api-key auth. Use OAuth sign-in in Gemini CLI.";
    }
    if (authType === "vertex-ai") {
      throw "Gemini usage unavailable for vertex-ai auth. Use OAuth sign-in in Gemini CLI.";
    }
    throw "Gemini usage unavailable for unsupported auth type: " + authType + ". Use OAuth sign-in in Gemini CLI.";
  }

  function decodeIdToken(ctx, idToken) {
    if (!idToken) return null;
    return ctx.jwt.decodePayload(idToken) || null;
  }

  function loadOauthCreds(ctx) {
    const creds = readJson(ctx, OAUTH_CREDS_PATH);
    if (!creds || !creds.access_token || !creds.id_token) {
      ctx.host.log.warn("no valid OAuth credentials found");
      return null;
    }
    ctx.host.log.info("OAuth credentials loaded");
    return creds;
  }

  function saveOauthCreds(ctx, creds) {
    try {
      ctx.host.fs.writeText(OAUTH_CREDS_PATH, JSON.stringify(creds, null, 2));
    } catch (e) {
      ctx.host.log.error("failed to write oauth_creds.json: " + String(e));
    }
  }

  function tokenExpiresAtMs(ctx, creds) {
    const expiry = creds && creds.expiry_date;
    const parsed = ctx.util.parseDateMs(expiry);
    return typeof parsed === "number" ? parsed : null;
  }

  function needsRefresh(ctx, creds) {
    return ctx.util.needsRefreshByExpiry({
      nowMs: Date.now(),
      expiresAtMs: tokenExpiresAtMs(ctx, creds),
      bufferMs: REFRESH_BUFFER_MS,
    });
  }

  function refreshToken(ctx, creds) {
    if (!creds.refresh_token) {
      throw SESSION_EXPIRED_MSG;
    }

    ctx.host.log.info("attempting token refresh");
    let resp;
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
          encodeURIComponent(OAUTH_CLIENT_ID) +
          "&client_secret=" +
          encodeURIComponent(OAUTH_CLIENT_SECRET) +
          "&refresh_token=" +
          encodeURIComponent(creds.refresh_token) +
          "&grant_type=refresh_token",
        timeoutMs: 15000,
      });
    } catch (e) {
      ctx.host.log.error("token refresh request failed: " + String(e));
      return null;
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw SESSION_EXPIRED_MSG;
    }
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("token refresh returned status " + resp.status);
      return null;
    }

    const body = ctx.util.tryParseJson(resp.bodyText);
    if (!body || !body.access_token) {
      ctx.host.log.warn("token refresh response missing access_token");
      return null;
    }

    creds.access_token = body.access_token;
    if (body.refresh_token) creds.refresh_token = body.refresh_token;
    if (body.id_token) creds.id_token = body.id_token;
    if (typeof body.expires_in === "number") {
      creds.expiry_date = Date.now() + body.expires_in * 1000;
    }

    saveOauthCreds(ctx, creds);
    ctx.host.log.info("refresh succeeded, expires in " + (body.expires_in || "unknown") + "s");
    return creds.access_token;
  }

  function postJson(ctx, url, accessToken, body) {
    return ctx.util.request({
      method: "POST",
      url: url,
      headers: {
        Authorization: "Bearer " + accessToken,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      bodyText: JSON.stringify(body || {}),
      timeoutMs: 10000,
    });
  }

  function readStringField(obj, keys) {
    if (!obj || typeof obj !== "object") return null;
    for (let i = 0; i < keys.length; i += 1) {
      const value = obj[keys[i]];
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return null;
  }

  function mapTierToPlan(tier, idTokenPayload) {
    if (!tier) return null;
    const normalized = String(tier).trim().toLowerCase();
    if (normalized === "standard-tier") return "Paid";
    if (normalized === "legacy-tier") return "Legacy";
    if (normalized === "free-tier") {
      return idTokenPayload && idTokenPayload.hd ? "Workspace" : "Free";
    }
    return null;
  }

  function discoverProjectId(ctx, accessToken, loadCodeAssistData) {
    const fromLoadCodeAssist = readStringField(loadCodeAssistData, ["cloudaicompanionProject"]);
    if (fromLoadCodeAssist) return fromLoadCodeAssist;

    let projectsResp;
    try {
      projectsResp = ctx.util.request({
        method: "GET",
        url: PROJECTS_URL,
        headers: {
          Authorization: "Bearer " + accessToken,
          Accept: "application/json",
        },
        timeoutMs: 10000,
      });
    } catch (e) {
      ctx.host.log.warn("project discovery failed: " + String(e));
      return null;
    }

    if (projectsResp.status < 200 || projectsResp.status >= 300) return null;
    const projectsData = ctx.util.tryParseJson(projectsResp.bodyText);
    const projects =
      projectsData && Array.isArray(projectsData.projects) ? projectsData.projects : [];
    if (!projects.length) return null;

    for (let i = 0; i < projects.length; i += 1) {
      const project = projects[i];
      const projectId =
        project && typeof project.projectId === "string" ? project.projectId : null;
      if (!projectId) continue;
      if (projectId.indexOf("gen-lang-client") === 0) return projectId;
      const labels =
        project && project.labels && typeof project.labels === "object" ? project.labels : null;
      if (labels && labels["generative-language"] !== undefined) return projectId;
    }
    return null;
  }

  function collectQuotaBuckets(value, out) {
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i += 1) collectQuotaBuckets(value[i], out);
      return;
    }
    if (!value || typeof value !== "object") return;
    if (typeof value.remainingFraction === "number") {
      const modelId =
        typeof value.modelId === "string"
          ? value.modelId
          : typeof value.model_id === "string"
            ? value.model_id
            : null;
      out.push({
        modelId: modelId || "unknown",
        remainingFraction: value.remainingFraction,
        resetTime: value.resetTime || value.reset_time || null,
      });
      return;
    }
    const nested = Object.values(value);
    for (let i = 0; i < nested.length; i += 1) {
      collectQuotaBuckets(nested[i], out);
    }
  }

  function toUsageLine(ctx, label, bucket) {
    const clampedRemaining = Math.max(0, Math.min(1, Number(bucket.remainingFraction)));
    const used = Math.round((1 - clampedRemaining) * 100);
    const resetsAt = ctx.util.toIso(bucket.resetTime);
    return ctx.line.progress({
      label: label,
      used: used,
      limit: 100,
      format: { kind: "percent" },
      resetsAt: resetsAt || undefined,
    });
  }

  function pickLowestRemainingBucket(buckets) {
    if (!buckets.length) return null;
    let best = null;
    for (let i = 0; i < buckets.length; i += 1) {
      const bucket = buckets[i];
      if (!Number.isFinite(bucket.remainingFraction)) continue;
      if (!best || bucket.remainingFraction < best.remainingFraction) {
        best = bucket;
      }
    }
    return best;
  }

  function parseQuotaLines(ctx, quotaData) {
    const buckets = [];
    collectQuotaBuckets(quotaData, buckets);
    if (!buckets.length) return [];

    const byModel = {};
    for (let i = 0; i < buckets.length; i += 1) {
      const bucket = buckets[i];
      const modelId = String(bucket.modelId || "")
        .replace(/[_-]+/g, " ")
        .replace(/\s+/g, " ")
        .trim();
      if (!modelId) continue;
      if (!byModel[modelId] || bucket.remainingFraction < byModel[modelId].remainingFraction) {
        byModel[modelId] = bucket;
      }
    }

    const allBuckets = Object.values(byModel);
    const proBuckets = [];
    const flashBuckets = [];
    for (let i = 0; i < allBuckets.length; i += 1) {
      const bucket = allBuckets[i];
      const lower = String(bucket.modelId || "").toLowerCase();
      if (lower.indexOf("gemini") !== -1 && lower.indexOf("pro") !== -1) {
        proBuckets.push(bucket);
      } else if (lower.indexOf("gemini") !== -1 && lower.indexOf("flash") !== -1) {
        flashBuckets.push(bucket);
      }
    }

    const lines = [];
    const pro = pickLowestRemainingBucket(proBuckets);
    if (pro) lines.push(toUsageLine(ctx, "Pro", pro));
    const flash = pickLowestRemainingBucket(flashBuckets);
    if (flash) lines.push(toUsageLine(ctx, "Flash", flash));
    return lines;
  }

  function fetchWithRetry(ctx, accessToken, creds, url, body, label) {
    let currentToken = accessToken;
    let didRefresh = false;
    let resp;
    try {
      resp = ctx.util.retryOnceOnAuth({
        request: function (token) {
          return postJson(ctx, url, token || currentToken, body);
        },
        refresh: function () {
          didRefresh = true;
          const refreshed = refreshToken(ctx, creds);
          if (refreshed) currentToken = refreshed;
          return refreshed;
        },
      });
    } catch (e) {
      if (typeof e === "string") throw e;
      ctx.host.log.error(label + " request failed: " + String(e));
      return { resp: null, accessToken: currentToken, didRefresh: didRefresh };
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw SESSION_EXPIRED_MSG;
    }
    return { resp: resp, accessToken: currentToken, didRefresh: didRefresh };
  }

  function probe(ctx) {
    assertSupportedAuthType(ctx);
    const creds = loadOauthCreds(ctx);
    if (!creds) {
      throw "Not logged in. Run `gemini auth login` to authenticate.";
    }

    let accessToken = creds.access_token;

    if (needsRefresh(ctx, creds)) {
      ctx.host.log.info("token needs refresh (expired or expiring soon)");
      const refreshed = refreshToken(ctx, creds);
      if (refreshed) {
        accessToken = refreshed;
      } else if (!accessToken) {
        throw "Not logged in. Run `gemini auth login` to authenticate.";
      }
    }

    const idTokenPayload = decodeIdToken(ctx, creds.id_token);

    let lcaResult = fetchWithRetry(ctx, accessToken, creds, LOAD_CODE_ASSIST_URL, { metadata: IDE_METADATA }, "loadCodeAssist");
    accessToken = lcaResult.accessToken;
    let loadCodeAssistData = null;
    if (lcaResult.resp && lcaResult.resp.status >= 200 && lcaResult.resp.status < 300) {
      loadCodeAssistData = ctx.util.tryParseJson(lcaResult.resp.bodyText);
    }
    const tier =
      readStringField(loadCodeAssistData, ["tier", "userTier", "subscriptionTier"]) ||
      (loadCodeAssistData && loadCodeAssistData.currentTier && loadCodeAssistData.currentTier.id) ||
      null;
    const plan = mapTierToPlan(tier, idTokenPayload);

    const projectId = discoverProjectId(ctx, accessToken, loadCodeAssistData);
    const quotaBody = projectId ? { project: projectId } : {};
    const quotaResult = fetchWithRetry(ctx, accessToken, creds, QUOTA_URL, quotaBody, "quota");
    accessToken = quotaResult.accessToken;
    if (!quotaResult.resp) {
      throw "Gemini quota request failed. Check your connection.";
    }
    if (quotaResult.resp.status < 200 || quotaResult.resp.status >= 300) {
      if (quotaResult.didRefresh) {
        throw "Gemini quota request failed after refresh. Try again.";
      }
      throw "Gemini quota request failed (HTTP " + String(quotaResult.resp.status) + "). Try again later.";
    }
    const quotaData = ctx.util.tryParseJson(quotaResult.resp.bodyText);
    if (!quotaData || typeof quotaData !== "object") {
      throw "Gemini quota response invalid. Try again later.";
    }

    ctx.host.log.info("usage fetch succeeded");

    const lines = parseQuotaLines(ctx, quotaData);
    const email =
      idTokenPayload && typeof idTokenPayload.email === "string" ? idTokenPayload.email : null;
    if (email) {
      lines.push(ctx.line.text({ label: "Account", value: email }));
    }

    if (lines.length === 0) {
      lines.push(
        ctx.line.badge({ label: "Status", text: "No usage data", color: "#a3a3a3" }),
      );
    }

    return { plan: plan || undefined, lines: lines };
  }

  globalThis.__openusage_plugin = { id: "gemini", probe };
})()
