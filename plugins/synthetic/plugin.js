(function () {
  var API_URL = "https://api.synthetic.new/v2/quotas";
  var ONE_HOUR_MS = 60 * 60 * 1000;

  var DEFAULT_PI_AGENT_DIR = "~/.pi/agent";
  var FACTORY_SETTINGS_PATH = "~/.factory/settings.json";
  var OPENCODE_AUTH_PATH = "~/.local/share/opencode/auth.json";

  // Provider names a user might register Synthetic under in various harnesses
  var PROVIDER_NAMES = ["synthetic", "synthetic.new", "syn"];

  function resolvePiAgentDir(ctx) {
    var envDir = ctx.host.env.get("PI_CODING_AGENT_DIR");
    if (typeof envDir === "string" && envDir.trim()) {
      return envDir.trim();
    }
    return DEFAULT_PI_AGENT_DIR;
  }

  function extractKey(value) {
    if (typeof value === "string" && value.trim()) return value.trim();
    return null;
  }

  // Search a parsed JSON object for a Synthetic API key under known provider names
  function findKeyInProviderMap(obj) {
    if (!obj || typeof obj !== "object") return null;
    for (var i = 0; i < PROVIDER_NAMES.length; i++) {
      var entry = obj[PROVIDER_NAMES[i]];
      if (!entry) continue;
      // Pi auth.json style: { "synthetic": { "type": "api_key", "key": "syn_..." } }
      var k = extractKey(entry.key);
      if (k) return k;
      // Pi models.json style: { "providers": { "synthetic": { "apiKey": "syn_..." } } }
      k = extractKey(entry.apiKey);
      if (k) return k;
    }
    return null;
  }

  function tryReadJson(ctx, path) {
    try {
      if (!ctx.host.fs.exists(path)) return null;
      return ctx.util.tryParseJson(ctx.host.fs.readText(path));
    } catch (e) {
      ctx.host.log.warn("Failed to read " + path + ": " + e);
      return null;
    }
  }

  function hasUsableRollingFiveHourLimit(value) {
    return (
      value &&
      typeof value.max === "number" &&
      typeof value.remaining === "number"
    );
  }

  function hasUsableWeeklyTokenLimit(value) {
    return value && typeof value.percentRemaining === "number";
  }

  function normalizeApiErrorMessage(json, status) {
    var fallback = "Request failed (HTTP " + status + ")";
    if (!json || typeof json !== "object") return fallback;

    var direct = typeof json.error === "string" ? json.error.trim() : "";
    if (direct) return direct;

    if (json.error && typeof json.error === "object") {
      var nested = typeof json.error.message === "string" ? json.error.message.trim() : "";
      if (nested) return nested;

      var serialized = JSON.stringify(json.error);
      if (serialized && serialized !== "{}") return serialized;
    }

    var message = typeof json.message === "string" ? json.message.trim() : "";
    if (message) return message;

    return fallback;
  }

  function loadApiKey(ctx) {
    var piDir = resolvePiAgentDir(ctx);

    // 1. Pi auth.json — primary source
    var piAuth = tryReadJson(ctx, piDir + "/auth.json");
    var key = findKeyInProviderMap(piAuth);
    if (key) return key;

    // 2. Pi models.json — custom provider config with apiKey field
    var piModels = tryReadJson(ctx, piDir + "/models.json");
    if (piModels && piModels.providers) {
      key = findKeyInProviderMap(piModels.providers);
      if (key) return key;
    }

    // 3. Factory/Droid settings.json — custom models with synthetic.new baseUrl
    var factorySettings = tryReadJson(ctx, FACTORY_SETTINGS_PATH);
    if (factorySettings && Array.isArray(factorySettings.customModels)) {
      for (var i = 0; i < factorySettings.customModels.length; i++) {
        var model = factorySettings.customModels[i];
        if (
          model &&
          typeof model.baseUrl === "string" &&
          model.baseUrl.indexOf("synthetic.new") !== -1
        ) {
          key = extractKey(model.apiKey);
          if (key) return key;
        }
      }
    }

    // 4. OpenCode auth.json
    var ocAuth = tryReadJson(ctx, OPENCODE_AUTH_PATH);
    key = findKeyInProviderMap(ocAuth);
    if (key) return key;

    // 5. SYNTHETIC_API_KEY env var
    var envKey = ctx.host.env.get("SYNTHETIC_API_KEY");
    if (typeof envKey === "string" && envKey.trim()) {
      return envKey.trim();
    }

    return null;
  }

  function probe(ctx) {
    var apiKey = loadApiKey(ctx);
    if (!apiKey) {
      throw "Synthetic API key not found. Set SYNTHETIC_API_KEY or add key to ~/.pi/agent/auth.json";
    }

    var resp, json;
    try {
      var result = ctx.util.requestJson({
        method: "GET",
        url: API_URL,
        headers: {
          Authorization: "Bearer " + apiKey,
          Accept: "application/json",
        },
        timeoutMs: 15000,
      });
      resp = result.resp;
      json = result.json;
    } catch (e) {
      throw "Request failed. Check your connection.";
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "API key invalid or expired. Check your Synthetic API key.";
    }

    if (resp.status < 200 || resp.status >= 300) {
      var msg = normalizeApiErrorMessage(json, resp.status);
      throw msg;
    }

    if (!json) {
      throw "Could not parse usage data.";
    }

    var lines = [];

    // 5h Rate Limit — hero metric (immediate blocker)
    if (hasUsableRollingFiveHourLimit(json.rollingFiveHourLimit)) {
      var rfl = json.rollingFiveHourLimit;
      var rflUsed = Math.max(0, rfl.max - rfl.remaining);
      lines.push(ctx.line.progress({
        label: "5h Rate Limit",
        used: rflUsed,
        limit: rfl.max,
        format: { kind: "count", suffix: "requests" },
      }));
    }

    // Mana Bar — longer-term weekly budget
    if (hasUsableWeeklyTokenLimit(json.weeklyTokenLimit)) {
      var pct = json.weeklyTokenLimit.percentRemaining;
      var manaUsed = Math.max(0, Math.round(100 - pct));
      lines.push(ctx.line.progress({
        label: "Mana Bar",
        used: manaUsed,
        limit: 100,
        format: { kind: "percent" },
      }));
    }

    // Rate Limited badge — only when actively limited
    if (
      json.rollingFiveHourLimit &&
      json.rollingFiveHourLimit.limited === true
    ) {
      lines.push(
        ctx.line.badge({
          label: "Rate Limited",
          text: "Rate limited",
          color: "#ef4444",
        })
      );
    }

    // Subscription — legacy request count, only shown if NOT on v3 rate limits
    var onV3 =
      hasUsableRollingFiveHourLimit(json.rollingFiveHourLimit) ||
      hasUsableWeeklyTokenLimit(json.weeklyTokenLimit);
    if (!onV3 && json.subscription && typeof json.subscription.limit === "number") {
      var sub = json.subscription;
      var subOpts = {
        label: "Subscription",
        used: sub.requests,
        limit: sub.limit,
        format: { kind: "count", suffix: "requests" },
      };
      var subReset = ctx.util.toIso(sub.renewsAt);
      if (subReset) subOpts.resetsAt = subReset;
      lines.push(ctx.line.progress(subOpts));
    }

    // Free Tool Calls — legacy only, zeroed out on v3
    if (!onV3 && json.freeToolCalls && typeof json.freeToolCalls.limit === "number" && json.freeToolCalls.limit > 0) {
      var ftc = json.freeToolCalls;
      var ftcOpts = {
        label: "Free Tool Calls",
        used: Math.round(ftc.requests),
        limit: ftc.limit,
        format: { kind: "count", suffix: "requests" },
      };
      var ftcReset = ctx.util.toIso(ftc.renewsAt);
      if (ftcReset) ftcOpts.resetsAt = ftcReset;
      lines.push(ctx.line.progress(ftcOpts));
    }

    // Search — hourly search quota (detail)
    if (
      json.search &&
      json.search.hourly &&
      typeof json.search.hourly.limit === "number"
    ) {
      var srch = json.search.hourly;
      var srchOpts = {
        label: "Search",
        used: srch.requests,
        limit: srch.limit,
        format: { kind: "count", suffix: "requests" },
        periodDurationMs: ONE_HOUR_MS,
      };
      var srchReset = ctx.util.toIso(srch.renewsAt);
      if (srchReset) srchOpts.resetsAt = srchReset;
      lines.push(ctx.line.progress(srchOpts));
    }

    return { lines: lines };
  }

  globalThis.__openusage_plugin = { id: "synthetic", probe: probe };
})();
