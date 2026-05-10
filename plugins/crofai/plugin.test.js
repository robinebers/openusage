import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makeCtx } from "../test-helpers.js";

var PLUGIN_DATA_DIR = "/tmp/openusage-test/plugin";
var SESSION_KEY_PATH = PLUGIN_DATA_DIR + "/session-key";
var API_KEY_ENV = "CROF_AI_API_KEY";
var SESSION_KEY_ENV = "CROF_AI_SESSION_KEY";
var USAGE_API_URL = "https://crof.ai/usage_api/";
var USER_USAGE_URL = "https://crof.ai/user-api/usage";
var PRICING_URL = "https://crof.ai/pricing_api";

var loadPlugin = async function () {
  await import("./plugin.js");
  return globalThis.__openusage_plugin;
};

function setEnv(ctx, name, value) {
  if (!ctx._env) ctx._env = {};
  ctx._env[name] = value;
  ctx.host.env.get.mockImplementation(function (n) {
    return ctx._env[n] !== undefined ? ctx._env[n] : null;
  });
}

function setSessionKeyFile(ctx, value) {
  ctx.host.fs.writeText(SESSION_KEY_PATH, value);
}

function mockUsageApi(ctx, body) {
  ctx.host.http.request.mockImplementation(function (opts) {
    if (opts.url === USAGE_API_URL) return { status: 200, headers: {}, bodyText: String(body) };
    return { status: 404, headers: {}, bodyText: "Not found" };
  });
}

function mockAllApis(ctx, options) {
  var usageBody = (options && options.usageBody !== undefined)
    ? options.usageBody
    : JSON.stringify({ usable_requests: 1938, credits: 42.5 });

  var pricingBody = (options && options.pricingBody !== undefined)
    ? options.pricingBody
    : JSON.stringify({ cost: 20, name: "int", requests: 2500, type: "normal" });

  var usageDetailBody = (options && options.usageDetailBody !== undefined)
    ? options.usageDetailBody
    : JSON.stringify({
        "deepseek-v4-pro": { input_tokens: 1083491205, output_tokens: 6249083, total_tokens: 1089740288 },
        "kimi-k2.6": { input_tokens: 36754651, output_tokens: 232694, total_tokens: 36987345 },
      });

  ctx.host.http.request.mockImplementation(function (opts) {
    if (opts.url === USAGE_API_URL) return { status: 200, headers: {}, bodyText: String(usageBody) };
    if (opts.url === USER_USAGE_URL) return { status: 200, headers: {}, bodyText: String(usageDetailBody) };
    if (opts.url === PRICING_URL) return { status: 200, headers: {}, bodyText: String(pricingBody) };
    return { status: 404, headers: {}, bodyText: "Not found" };
  });
}

describe("crofai plugin", function () {
  beforeEach(function () {
    delete globalThis.__openusage_plugin;
    vi.resetModules();
  });

  afterEach(function () {
    vi.restoreAllMocks();
  });

  // ── Manifest ──

  it("ships plugin metadata with links and expected line layout", function () {
    var manifest = JSON.parse(readFileSync("plugins/crofai/plugin.json", "utf8"));
    expect(manifest.id).toBe("crofai");
    expect(manifest.name).toBe("Crof.AI");
    expect(manifest.brandColor).toBe("#6B52F2");
    expect(manifest.links).toEqual([{ label: "Dashboard", url: "https://crof.ai" }]);
    expect(manifest.lines).toEqual([
      { type: "badge", label: "Status", scope: "overview" },
      { type: "progress", label: "Requests", scope: "overview", primaryOrder: 1 },
      { type: "text", label: "Credits", scope: "overview" },
      { type: "text", label: "Total tokens", scope: "overview" },
      { type: "text", label: "Models", scope: "detail" },
    ]);
  });

  // ── Auth: API key validation ──

  describe("auth - API key", function () {
    it("throws when CROF_AI_API_KEY is missing", async function () {
      var ctx = makeCtx();
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI not configured");
    });

    it("throws when CROF_AI_API_KEY is empty string", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "");
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI not configured");
    });

    it("throws when CROF_AI_API_KEY is only whitespace", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "   \t  ");
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI not configured");
    });

    it("throws when CROF_AI_API_KEY is null", async function () {
      var ctx = makeCtx();
      ctx.host.env.get.mockReturnValue(null);
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI not configured");
    });

    it("throws when CROF_AI_API_KEY is a non-string (number)", async function () {
      var ctx = makeCtx();
      ctx.host.env.get.mockReturnValue(123);
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI not configured");
    });

    it("sends GET with Bearer auth to correct URL", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "test-api-key");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: 10 }));
      var plugin = await loadPlugin();
      plugin.probe(ctx);

      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.method).toBe("GET");
      expect(call.url).toBe(USAGE_API_URL);
      expect(call.headers.Authorization).toBe("Bearer test-api-key");
      expect(call.Accept).toBe("application/json");
      expect(call.timeoutMs).toBe(10000);
    });
  });

  // ── HTTP error handling ──

  describe("HTTP error handling", function () {
    it("throws on network error", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockImplementation(function () { throw new Error("ECONNREFUSED"); });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI network error");
    });

    it("throws on HTTP 401", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI auth expired");
    });

    it("throws on HTTP 403", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 403, headers: {}, bodyText: "" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI auth expired");
    });

    it("throws on HTTP 500", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 500, headers: {}, bodyText: "Server error" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI API error (HTTP 500)");
    });

    it("throws on HTTP 300 (non-2xx boundary)", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 300, headers: {}, bodyText: "Redirect" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI API error (HTTP 300)");
    });

    it("throws on HTTP 404", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 404, headers: {}, bodyText: "Not found" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI API error (HTTP 404)");
    });
  });

  // ── Response validation: body shape ──

  describe("response validation - body shape", function () {
    it("throws on unparseable JSON", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, "not-json");
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws on null bodyText", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 200, headers: {}, bodyText: null });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws on empty bodyText", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 200, headers: {}, bodyText: "" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws on array response body", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify([1, 2, 3]));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws on string response body", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, '"hello"');
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws on number response body", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, "42");
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });
  });

  // ── Response validation: credits field ──

  describe("response validation - credits field", function () {
    it("throws when credits is Infinity", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, '{"credits":1e999,"usable_requests":10}');
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws when credits is NaN", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, '{"credits":NaN,"usable_requests":10}');
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws when credits is a string", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: "abc", usable_requests: 10 }));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws when credits is a boolean", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: true, usable_requests: 10 }));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws when credits is an object", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: {}, usable_requests: 10 }));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });
  });

  // ── Response validation: usable_requests field ──

  describe("response validation - usable_requests field", function () {
    it("throws when usable_requests is a string", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: 10, usable_requests: "50" }));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws when usable_requests is a boolean", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: 10, usable_requests: false }));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("throws when usable_requests is an object", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: 10, usable_requests: { x: 1 } }));
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });

    it("works when usable_requests is null (no subscription)", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: 5, usable_requests: null }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", used: 0, limit: 15000 });
    });

    it("works when usable_requests field is entirely absent", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ credits: 5 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", used: 0, limit: 15000 });
    });
  });

  // ── Progress bar ──

  describe("progress bar - limit sources", function () {
    it("uses pricing API plan limit when session key available", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "int", requests: 2500 }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", limit: 2500 });
    });

    it("uses requests_plan from usage API when no session key", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 300, credits: 10, requests_plan: 1000 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", used: 700, limit: 1000 });
    });

    it("uses 15000 fallback when no pricing and no requests_plan", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 500, credits: 10 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", limit: 15000 });
    });

    it("clamps used to 0 when usable_requests exceeds limit", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 200, credits: 10, requests_plan: 100 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", used: 0, limit: 100 });
    });

    it("calculates used correctly when usable < limit", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: 10, requests_plan: 500 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ type: "progress", used: 400, limit: 500 });
    });

    it("pricing API takes priority over usage requests_plan", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      // usage API has requests_plan = 500, but pricing has requests = 2500
      mockAllApis(ctx, {
        usageBody: JSON.stringify({ usable_requests: 100, credits: 10, requests_plan: 500 }),
        pricingBody: JSON.stringify({ name: "int", requests: 2500 }),
      });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ limit: 2500 });
    });
  });

  // ── Progress bar: fallback on session-dependent API failures ──

  describe("progress bar - fallback on failures", function () {
    it("falls back from pricing failure to usage requests_plan", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      ctx.host.http.request.mockImplementation(function (opts) {
        if (opts.url === USAGE_API_URL) return { status: 200, headers: {}, bodyText: JSON.stringify({ usable_requests: 300, credits: 10, requests_plan: 1000 }) };
        if (opts.url === PRICING_URL) return { status: 500, headers: {}, bodyText: "" };
        return { status: 404, headers: {}, bodyText: "" };
      });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ limit: 1000 });
    });

    it("falls back to 15000 when both pricing and requests_plan fail", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      ctx.host.http.request.mockImplementation(function (opts) {
        if (opts.url === USAGE_API_URL) return { status: 200, headers: {}, bodyText: JSON.stringify({ usable_requests: 300, credits: 10 }) };
        if (opts.url === PRICING_URL) return { status: 500, headers: {}, bodyText: "" };
        return { status: 404, headers: {}, bodyText: "" };
      });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[0]).toMatchObject({ limit: 15000 });
      expect(result.plan).toBeNull();
    });

    it("pricing failure logs warning and returns no plan", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      ctx.host.http.request.mockImplementation(function (opts) {
        if (opts.url === USAGE_API_URL) return { status: 200, headers: {}, bodyText: JSON.stringify({ usable_requests: 500, credits: 10 }) };
        return { status: 403, headers: {}, bodyText: "" };
      });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(ctx.host.log.warn).toHaveBeenCalled();
      expect(result.plan).toBeNull();
    });

    it("user usage failure logs warning but does not affect main lines", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      ctx.host.http.request.mockImplementation(function (opts) {
        if (opts.url === USAGE_API_URL) return { status: 200, headers: {}, bodyText: JSON.stringify({ usable_requests: 500, credits: 10 }) };
        if (opts.url === USER_USAGE_URL) return { status: 500, headers: {}, bodyText: "" };
        if (opts.url === PRICING_URL) return { status: 200, headers: {}, bodyText: JSON.stringify({ name: "int", requests: 2500 }) };
        return { status: 404, headers: {}, bodyText: "" };
      });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(ctx.host.log.warn).toHaveBeenCalled();
      expect(result.lines[0]).toMatchObject({ type: "progress", limit: 2500 });
      expect(result.plan).toBe("Intermediate");
    });
  });

  // ── Credits display ──

  describe("credits display", function () {
    it("shows positive credits formatted as dollars", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: 42.5 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[1]).toMatchObject({ label: "Credits", value: "$42.50" });
    });

    it("shows zero credits as $0.00", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: 0 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[1]).toMatchObject({ label: "Credits", value: "$0.00" });
    });

    it("omits credits line when credits is negative", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: -5 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Credits"; })).toBeUndefined();
    });

    it("shows very small positive credits (< $0.01) as $0.00", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: 0.005 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[1]).toMatchObject({ label: "Credits", value: "$0.00" });
    });

    it("shows $0.00 when credits field is missing from response", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[1]).toMatchObject({ label: "Credits", value: "$0.00" });
    });

    it("formats credits with two decimal places", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 100, credits: 12.3456 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines[1].value).toBe("$12.35");
    });
  });

  // ── Plan name ──

  describe("plan name", function () {
    it("returns null plan when no session key", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      expect(plugin.probe(ctx).plan).toBeNull();
    });

    it("returns mapped plan name for int", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "int", requests: 2500 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Intermediate");
    });

    it("returns mapped plan name for hobby", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "hobby", requests: 500 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Hobby");
    });

    it("returns mapped plan name for pro", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "pro", requests: 1000 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Pro");
    });

    it("returns mapped plan name for scale", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "scale", requests: 7500 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Scale");
    });

    it("returns mapped plan name for max", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "max", requests: 15000 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Max");
    });

    it("falls through to fmt.planLabel for unknown plan names", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "enterprise_plus", requests: 9999 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Enterprise_plus");
    });

    it("handles case-insensitive plan names", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ name: "INT", requests: 2500 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Intermediate");
    });

    it("returns null plan when pricing has no name field", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { pricingBody: JSON.stringify({ requests: 2500 }) });
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBeNull();
    });
  });

  // ── Session key sources ──

  describe("session key sources", function () {
    it("reads session key from env var", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "env-session");
      mockAllApis(ctx);
      var p = await loadPlugin();
      expect(p.probe(ctx).plan).toBe("Intermediate");
    });

    it("reads session key from file", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setSessionKeyFile(ctx, "file-session");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      expect(plugin.probe(ctx).plan).toBe("Intermediate");
    });

    it("env var takes priority over file", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "env-session");
      setSessionKeyFile(ctx, "file-session");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      var calls = ctx.host.http.request.mock.calls;
      for (var i = 0; i < calls.length; i++) {
        var opts = calls[i][0];
        if (opts.url === PRICING_URL) {
          expect(opts.headers.Cookie).toBe("session=env-session");
        }
      }
    });

    it("returns null session key when env var is empty and file missing", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      // Should still work with just API key data
      var result = plugin.probe(ctx);
      expect(result.plan).toBeNull();
      expect(result.lines[0]).toBeDefined();
    });

    it("returns null session key when file is empty", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setSessionKeyFile(ctx, "");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      expect(plugin.probe(ctx).plan).toBeNull();
    });

    it("returns null session key when file only has whitespace", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setSessionKeyFile(ctx, "   \n  ");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      expect(plugin.probe(ctx).plan).toBeNull();
    });

    it("uses session key via API calls to user-usage and pricing", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "my-session-key");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      plugin.probe(ctx);

      var usageCall = ctx.host.http.request.mock.calls[1];
      var pricingCall = ctx.host.http.request.mock.calls[2];
      expect(usageCall[0].url).toBe(USER_USAGE_URL);
      expect(usageCall[0].headers.Cookie).toBe("session=my-session-key");
      expect(pricingCall[0].url).toBe(PRICING_URL);
      expect(pricingCall[0].headers.Cookie).toBe("session=my-session-key");
    });
  });

  // ── Tokens and models ──

  describe("tokens and models", function () {
    it("shows total tokens line", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ "model-big": { total_tokens: 5000000 }, "model-small": { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      var totalLine = result.lines.find(function (l) { return l.label === "Total tokens"; });
      expect(totalLine).toBeDefined();
    });

    it("shows model count in subtitle", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ "model-big": { total_tokens: 5000000 }, "model-small": { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      var totalLine = result.lines.find(function (l) { return l.label === "Total tokens"; });
      expect(totalLine.subtitle).toBe("2 models");
    });

    it("sorts models descending by token count", async function () {
      var ctx2 = makeCtx();
      setEnv(ctx2, API_KEY_ENV, "k");
      setEnv(ctx2, SESSION_KEY_ENV, "s");
      mockAllApis(ctx2, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: 100 }, b: { total_tokens: 500 } }),
      });
      var p2 = await loadPlugin();
      var models = p2.probe(ctx2).lines.filter(function (l) { return l.label !== "Requests" && l.label !== "Credits" && l.label !== "Total tokens"; });
      expect(models[0].label).toBe("b");
      expect(models[1].label).toBe("a");
    });

    it("limits to 5 models maximum", async function () {
      var many = {};
      for (var i = 1; i <= 10; i++) many["m-" + i] = { total_tokens: (10 - i + 1) * 1000 };
      var ctx3 = makeCtx();
      setEnv(ctx3, API_KEY_ENV, "k");
      setEnv(ctx3, SESSION_KEY_ENV, "s");
      mockAllApis(ctx3, { usageDetailBody: JSON.stringify(many) });
      var p3 = await loadPlugin();
      var models = p3.probe(ctx3).lines.filter(function (l) { return /tokens/.test(l.value || ""); });
      expect(models.length).toBe(5);
    });

    it("skips models with zero tokens", async function () {
      var ctx4 = makeCtx();
      setEnv(ctx4, API_KEY_ENV, "k");
      setEnv(ctx4, SESSION_KEY_ENV, "s");
      mockAllApis(ctx4, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: 100 }, b: { total_tokens: 0 }, c: { total_tokens: 200 } }),
      });
      var p4 = await loadPlugin();
      var result = p4.probe(ctx4);
      var models = result.lines.filter(function (l) { return /tokens/.test(l.value || ""); });
      expect(models.length).toBe(2);
    });

    it("handles camelCase totalTokens field", async function () {
      var ctx5 = makeCtx();
      setEnv(ctx5, API_KEY_ENV, "k");
      setEnv(ctx5, SESSION_KEY_ENV, "s");
      mockAllApis(ctx5, {
        usageDetailBody: JSON.stringify({ a: { totalTokens: 3000 } }),
      });
      var p5 = await loadPlugin();
      var result = p5.probe(ctx5);
      var modelLine = result.lines.find(function (l) { return l.label === "a"; });
      expect(modelLine).toBeDefined();
      expect(modelLine.value).toBe("3.0K tokens");
    });

    it("skips models with string numeric total_tokens to avoid string concat", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: "5000" }, b: { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      var totalLine = result.lines.find(function (l) { return l.label === "Total tokens"; });
      expect(totalLine.value).toBe("1.0K");
      expect(result.lines.find(function (l) { return l.label === "a"; })).toBeUndefined();
    });

    it("skips models with boolean total_tokens", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: true }, b: { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      var totalLine = result.lines.find(function (l) { return l.label === "Total tokens"; });
      expect(totalLine.value).toBe("1.0K");
      expect(result.lines.find(function (l) { return l.label === "a"; })).toBeUndefined();
    });

    it("skips models with Infinity total_tokens", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: Infinity }, b: { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.0K");
    });

    it("skips models with negative total_tokens", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: -500 }, b: { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.0K");
    });

    it("skips models with object total_tokens", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: { x: 1 } }, b: { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.0K");
    });

    it("skips models with non-numeric string total_tokens", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: "abc" }, b: { total_tokens: 1000 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.0K");
    });

    it("prefers total_tokens over totalTokens when both present", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, {
        usageDetailBody: JSON.stringify({ a: { total_tokens: 2000, totalTokens: 999 } }),
      });
      var p = await loadPlugin();
      var result = p.probe(ctx);
      var modelLine = result.lines.find(function (l) { return l.label === "a"; });
      expect(modelLine.value).toBe("2.0K tokens");
    });

    it("shows no model lines when usage data is null", async function () {
      var ctx6 = makeCtx();
      setEnv(ctx6, API_KEY_ENV, "k");
      // No session key, so no usage detail data
      mockUsageApi(ctx6, JSON.stringify({ usable_requests: 100, credits: 10 }));
      var p6 = await loadPlugin();
      var result = p6.probe(ctx6);
      var modelLines = result.lines.filter(function (l) { return /tokens/.test(l.value || ""); });
      expect(modelLines.length).toBe(0);
    });

    it("shows total tokens as 0 when usage data is empty object", async function () {
      var ctx7 = makeCtx();
      setEnv(ctx7, API_KEY_ENV, "k");
      setEnv(ctx7, SESSION_KEY_ENV, "s");
      mockAllApis(ctx7, { usageDetailBody: "{}" });
      var p7 = await loadPlugin();
      var result = p7.probe(ctx7);
      var totalLine = result.lines.find(function (l) { return l.label === "Total tokens"; });
      expect(totalLine.value).toBe("0");
    });
  });

  // ── Token formatting ──

  describe("token formatting", function () {
    it("formats 0 tokens as '0'", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { usageDetailBody: JSON.stringify({ a: { total_tokens: 0 } }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("0");
    });

    it("formats tokens under 1000 as raw number", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { usageDetailBody: JSON.stringify({ a: { total_tokens: 999 } }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("999");
    });

    it("formats thousands as K", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { usageDetailBody: JSON.stringify({ a: { total_tokens: 1500 } }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.5K");
    });

    it("formats millions as M", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { usageDetailBody: JSON.stringify({ a: { total_tokens: 2500000 } }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("2.5M");
    });

    it("formats billions as B", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { usageDetailBody: JSON.stringify({ a: { total_tokens: 1200000000 } }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.2B");
    });

    it("formats exact 1B correctly", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx, { usageDetailBody: JSON.stringify({ a: { total_tokens: 1000000000 } }) });
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);
      expect(result.lines.find(function (l) { return l.label === "Total tokens"; }).value).toBe("1.0B");
    });
  });

  // ── Full happy path ──

  describe("happy path - full output", function () {
    it("returns progress, credits, total tokens, and model lines with session key", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      setEnv(ctx, SESSION_KEY_ENV, "s");
      mockAllApis(ctx);
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);

      expect(result.lines.length).toBe(5); // progress + credits + total tokens + 2 models
      expect(result.lines[0]).toMatchObject({ type: "progress", label: "Requests" });
      expect(result.lines[1]).toMatchObject({ type: "text", label: "Credits", value: "$42.50" });
      expect(result.lines[2]).toMatchObject({ type: "text", label: "Total tokens" });
      expect(result.lines[3].label).toBe("deepseek-v4-pro");
      expect(result.lines[4].label).toBe("kimi-k2.6");
      expect(result.plan).toBe("Intermediate");
    });

    it("returns progress and credits only without session key", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, JSON.stringify({ usable_requests: 500, credits: 25 }));
      var plugin = await loadPlugin();
      var result = plugin.probe(ctx);

      expect(result.lines.length).toBe(3); // progress + credits + total tokens (0)
      expect(result.lines[0]).toMatchObject({ type: "progress" });
      expect(result.lines[1]).toMatchObject({ type: "text", label: "Credits" });
      expect(result.lines[2]).toMatchObject({ type: "text", label: "Total tokens", value: "0" });
    });
  });

  // ── Error message matching ──

  describe("error messages", function () {
    it("throws specific message for missing API key", async function () {
      var ctx = makeCtx();
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI not configured");
    });

    it("throws specific message for network error", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockImplementation(function () { throw new Error("refused"); });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI network error");
    });

    it("throws specific message for auth errors", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI auth expired");
    });

    it("throws specific message for server errors", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      ctx.host.http.request.mockReturnValue({ status: 502, headers: {}, bodyText: "Bad gateway" });
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Crof.AI API error (HTTP 502)");
    });

    it("throws specific message for invalid response", async function () {
      var ctx = makeCtx();
      setEnv(ctx, API_KEY_ENV, "k");
      mockUsageApi(ctx, "not-json");
      var plugin = await loadPlugin();
      expect(function () { plugin.probe(ctx); }).toThrow("Invalid response from Crof.AI");
    });
  });
});
