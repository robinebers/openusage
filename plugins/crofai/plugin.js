(function () {
  var PROVIDER_ID = "crofai";
  var USAGE_API_URL = "https://crof.ai/usage_api/";
  var USER_USAGE_URL = "https://crof.ai/user-api/usage";
  var PRICING_URL = "https://crof.ai/pricing_api";
  var TIMEOUT_MS = 10000;
  var MAX_DISPLAY_MODELS = 5;

  var PLAN_NAMES = {
    hobby: "Hobby",
    pro: "Pro",
    int: "Intermediate",
    scale: "Scale",
    max: "Max",
  };
  var FALLBACK_MAX_REQUESTS = 15000;

  function readApiKey(ctx) {
    var raw = ctx.host.env.get("CROF_AI_API_KEY");
    if (typeof raw === "string" && raw.trim()) {
      return raw.trim();
    }
    throw (
      "Crof.AI not configured. Set CROF_AI_API_KEY env var.\n" +
      "Get your API key from https://crof.ai/usage_api/"
    );
  }

  function readSessionKey(ctx) {
    var raw = ctx.host.env.get("CROF_AI_SESSION_KEY");
    if (typeof raw === "string" && raw.trim()) {
      return raw.trim();
    }

    var keyPath = ctx.app.pluginDataDir + "/session-key";
    if (!ctx.host.fs.exists(keyPath)) {
      return null;
    }
    try {
      var key = ctx.host.fs.readText(keyPath).trim();
      return key || null;
    } catch (e) {
      return null;
    }
  }

  function requestJson(ctx, opts) {
    var resp;
    try {
      resp = ctx.host.http.request({
        method: "GET",
        url: opts.url,
        headers: opts.headers || {},
        Accept: "application/json",
        timeoutMs: TIMEOUT_MS,
      });
    } catch (e) {
      throw "Crof.AI network error. Check your connection.";
    }

    if (resp.status === 401 || resp.status === 403) {
      throw "Crof.AI auth expired. Check your API key or session key.";
    }

    if (resp.status !== 200) {
      throw "Crof.AI API error (HTTP " + resp.status + "). Try again later.";
    }

    var parsed = ctx.util.tryParseJson(resp.bodyText);
    if (parsed === null) {
      throw "Invalid response from Crof.AI. Try again later.";
    }
    return parsed;
  }

  function planFullName(raw) {
    if (!raw) return null;
    var lower = String(raw).toLowerCase().trim();
    return PLAN_NAMES[lower] || null;
  }

  function formatTokens(count) {
    if (count >= 1e9) {
      var b = count / 1e9;
      return (Math.round(b * 10) / 10).toFixed(1) + "B";
    }
    if (count >= 1e6) {
      var m = count / 1e6;
      return (Math.round(m * 10) / 10).toFixed(1) + "M";
    }
    if (count >= 1e3) {
      var k = count / 1e3;
      return (Math.round(k * 10) / 10).toFixed(1) + "K";
    }
    return String(count);
  }

  function formatCredits(raw) {
    var num = Number(raw);
    if (!Number.isFinite(num)) return "$0.00";
    var abs = Math.abs(num);
    if (abs < 0.01) return "$0.00";
    var sign = num < 0 ? "-" : "";
    return sign + "$" + abs.toFixed(2);
  }

  function buildLines(ctx, usageData, requestsCount, creditsValue, planInfo) {
    var lines = [];

    var maxRequests = FALLBACK_MAX_REQUESTS;
    if (
      planInfo &&
      typeof planInfo.requests === "number" &&
      planInfo.requests > 0
    ) {
      maxRequests = planInfo.requests;
    }

    var used = 0;
    if (requestsCount !== null) {
      used = maxRequests - requestsCount;
      if (used < 0) used = 0;
    }

    lines.push(
      ctx.line.progress({
        label: "Requests",
        used: used,
        limit: maxRequests,
        format: { kind: "count", suffix: "requests" },
      })
    );

    lines.push(
      ctx.line.text({
        label: "Credits",
        value: formatCredits(creditsValue),
      })
    );

    var models = [];
    var totalTokens = 0;

    if (usageData && typeof usageData === "object") {
      for (var key in usageData) {
        if (Object.prototype.hasOwnProperty.call(usageData, key)) {
          var model = usageData[key];
          var tt = model.total_tokens || model.totalTokens || 0;
          if (tt > 0) {
            totalTokens += tt;
            models.push({ name: key, tokens: tt });
          }
        }
      }
    }

    lines.push(
      ctx.line.text({
        label: "Total tokens",
        value: formatTokens(totalTokens),
        subtitle: models.length > 0 ? models.length + " models" : undefined,
      })
    );

    models.sort(function (a, b) {
      return b.tokens - a.tokens;
    });

    var topModels = models.slice(0, MAX_DISPLAY_MODELS);
    for (var i = 0; i < topModels.length; i++) {
      var m = topModels[i];
      lines.push(
        ctx.line.text({
          label: m.name,
          value: formatTokens(m.tokens) + " tokens",
        })
      );
    }

    return lines;
  }

  function probe(ctx) {
    var apiKey = readApiKey(ctx);

    var usageResp = requestJson(ctx, {
      url: USAGE_API_URL,
      headers: {
        Authorization: "Bearer " + apiKey,
      },
    });

    if (!usageResp || typeof usageResp !== "object" || Array.isArray(usageResp)) {
      throw "Invalid response from Crof.AI. Try again later.";
    }

    var hasCredits = "credits" in usageResp;
    var creditsValue = 0;
    if (hasCredits) {
      if (typeof usageResp.credits !== "number" || !Number.isFinite(usageResp.credits)) {
        throw "Invalid response from Crof.AI. Try again later.";
      }
      creditsValue = usageResp.credits;
    }

    var requestsCount = null;
    var hasRequests = "usable_requests" in usageResp;
    if (hasRequests) {
      if (usageResp.usable_requests !== null) {
        if (typeof usageResp.usable_requests !== "number" || !Number.isFinite(usageResp.usable_requests)) {
          throw "Invalid response from Crof.AI. Try again later.";
        }
        requestsCount = usageResp.usable_requests;
      }
    }

    var sessionKey = readSessionKey(ctx);

    var userUsageData = null;
    var planInfo = null;
    var planName = null;

    if (sessionKey) {
      try {
        userUsageData = requestJson(ctx, {
          url: USER_USAGE_URL,
          headers: {
            Cookie: "session=" + sessionKey,
          },
        });
      } catch (e) {
        ctx.host.log.warn("Crof.AI user usage fetch failed: " + String(e));
      }

      try {
        planInfo = requestJson(ctx, {
          url: PRICING_URL,
          headers: {
            Cookie: "session=" + sessionKey,
          },
        });
        if (planInfo && planInfo.name) {
          planName = planFullName(planInfo.name) || ctx.fmt.planLabel(planInfo.name);
        }
      } catch (e) {
        ctx.host.log.warn("Crof.AI pricing fetch failed: " + String(e));
      }
    }

    return {
      plan: planName,
      lines: buildLines(ctx, userUsageData, requestsCount, creditsValue, planInfo),
    };
  }

  globalThis.__openusage_plugin = { id: PROVIDER_ID, probe };
})();
