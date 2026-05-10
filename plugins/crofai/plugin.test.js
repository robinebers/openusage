import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makeCtx } from "../test-helpers.js";

const PLUGIN_DATA_DIR = "/tmp/openusage-test/plugin";
const SESSION_KEY_PATH = PLUGIN_DATA_DIR + "/session-key";
const API_KEY_ENV = "CROF_AI_API_KEY";
const SESSION_KEY_ENV = "CROF_AI_SESSION_KEY";

const loadPlugin = async () => {
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

function mockHttp(ctx, options) {
  var usageApiBody =
    (options && options.usageApiBody !== undefined)
      ? options.usageApiBody
      : JSON.stringify({ usable_requests: 1938, credits: 42.5 });

  var pricingBody =
    (options && options.pricingBody !== undefined)
      ? options.pricingBody
      : JSON.stringify({ cost: 20, name: "int", requests: 2500, type: "normal" });

  var userUsageBody =
    (options && options.userUsageBody !== undefined)
      ? options.userUsageBody
      : JSON.stringify({
          "deepseek-v4-pro": {
            input_tokens: 1083491205,
            output_tokens: 6249083,
            total_tokens: 1089740288,
          },
          "deepseek-v4-pro-precision": {
            input_tokens: 119901643,
            output_tokens: 517164,
            total_tokens: 120418807,
          },
          "glm-4.7-flash": {
            input_tokens: 1527962,
            output_tokens: 26246,
            total_tokens: 1554208,
          },
          "glm-5.1": {
            input_tokens: 7320364,
            output_tokens: 31617,
            total_tokens: 7351981,
          },
          "kimi-k2.5": {
            input_tokens: 6896,
            output_tokens: 4808,
            total_tokens: 11704,
          },
          "kimi-k2.5-lightning": {
            input_tokens: 6980,
            output_tokens: 840,
            total_tokens: 7820,
          },
          "kimi-k2.6": {
            input_tokens: 36754651,
            output_tokens: 232694,
            total_tokens: 36987345,
          },
        });

  ctx.host.http.request.mockImplementation((opts) => {
    if (opts.url === "https://crof.ai/usage_api/") {
      return { status: 200, headers: {}, bodyText: String(usageApiBody) };
    }
    if (opts.url === "https://crof.ai/user-api/usage") {
      return { status: 200, headers: {}, bodyText: String(userUsageBody) };
    }
    if (opts.url === "https://crof.ai/pricing_api") {
      return { status: 200, headers: {}, bodyText: String(pricingBody) };
    }
    return { status: 404, headers: {}, bodyText: "Not found" };
  });
}

describe("crofai plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin;
    vi.resetModules();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  // ---- Manifest ----

  it("ships plugin metadata with links and expected line layout", () => {
    var manifest = JSON.parse(
      readFileSync("plugins/crofai/plugin.json", "utf8"),
    );

    expect(manifest.id).toBe("crofai");
    expect(manifest.name).toBe("Crof.AI");
    expect(manifest.brandColor).toBe("#6B52F2");
    expect(manifest.links).toEqual([
      { label: "Dashboard", url: "https://crof.ai" },
    ]);
    expect(manifest.lines).toEqual([
      { type: "badge", label: "Status", scope: "overview" },
      { type: "progress", label: "Requests", scope: "overview", primaryOrder: 1 },
      { type: "text", label: "Credits", scope: "overview" },
      { type: "text", label: "Total tokens", scope: "overview" },
      { type: "text", label: "Models", scope: "detail" },
    ]);
  });

  // ---- Auth errors ----

  it("throws when API key env var is missing", async () => {
    var ctx = makeCtx();
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow(
      "Crof.AI not configured. Set CROF_AI_API_KEY",
    );
  });

  it("throws on network error", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockImplementation(() => { throw new Error("refused"); });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Crof.AI network error");
  });

  it("throws on 401", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({ status: 401, headers: {}, bodyText: "" });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Crof.AI auth expired");
  });

  // ---- Response validation ----

  it("throws on array response body", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {}, bodyText: JSON.stringify([1, 2]),
    });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Invalid response from Crof.AI");
  });

  it("throws when credits is Infinity", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: '{"credits":1e999,"usable_requests":10}',
    });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Invalid response from Crof.AI");
  });

  it("throws when usable_requests is a string", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: JSON.stringify({ credits: 10, usable_requests: "50" }),
    });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Invalid response from Crof.AI");
  });

  it("throws when usable_requests is a boolean", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: JSON.stringify({ credits: 10, usable_requests: true }),
    });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Invalid response from Crof.AI");
  });

  it("throws when credits is a string", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: JSON.stringify({ credits: "abc", usable_requests: 10 }),
    });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Invalid response from Crof.AI");
  });

  it("throws when usable_requests is NaN via large exponent", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: '{"credits":10,"usable_requests":NaN}',
    });
    var plugin = await loadPlugin();
    expect(() => plugin.probe(ctx)).toThrow("Invalid response from Crof.AI");
  });

  it("works with null usable_requests (no subscription)", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: JSON.stringify({ credits: 5, usable_requests: null }),
    });
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[0]).toMatchObject({ type: "progress", used: 0, limit: 15000 });
    expect(result.lines[1].value).toBe("$5.00");
  });

  it("works when usable_requests field is missing entirely", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: JSON.stringify({ credits: 5 }),
    });
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[0]).toMatchObject({ type: "progress", used: 0, limit: 15000 });
    expect(result.lines[1].value).toBe("$5.00");
  });

  it("works when credits field is missing", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {},
      bodyText: JSON.stringify({ usable_requests: 100 }),
    });
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[1].value).toBe("$0.00");
    expect(result.lines[0].used).toBe(14900);
  });

  // ---- Plan field ----

  it("returns no plan when no session key", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBeNull();
  });

  it("returns plan name when session key has pricing", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBe("Intermediate");
  });

  it("returns plan for hobby pricing", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx, { pricingBody: JSON.stringify({ name: "hobby", requests: 500 }) });
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBe("Hobby");
  });

  it("returns plan for pro pricing", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx, { pricingBody: JSON.stringify({ name: "pro", requests: 1000 }) });
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBe("Pro");
  });

  it("returns plan for scale pricing", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx, { pricingBody: JSON.stringify({ name: "scale", requests: 7500 }) });
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBe("Scale");
  });

  it("returns plan for max pricing", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx, { pricingBody: JSON.stringify({ name: "max", requests: 15000 }) });
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBe("Max");
  });

  it("falls through to fmt.planLabel for unknown plan names", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx, { pricingBody: JSON.stringify({ name: "enterprise_plus", requests: 9999 }) });
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).plan).toBe("Enterprise_plus");
  });

  // ---- Progress bar ----

  it("shows progress bar with 15000 fallback", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[0]).toMatchObject({
      type: "progress",
      label: "Requests",
      used: 13062,
      limit: 15000,
    });
  });

  it("shows progress bar with pricing data", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[0]).toMatchObject({
      type: "progress",
      label: "Requests",
      used: 562,
      limit: 2500,
    });
  });

  it("uses requests_plan from usage API when no session key", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    ctx.host.http.request.mockReturnValue({
      status: 200, headers: {}, bodyText: JSON.stringify({ usable_requests: 300, credits: 10, requests_plan: 1000 }),
    });
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[0]).toMatchObject({
      type: "progress",
      label: "Requests",
      used: 700,
      limit: 1000,
    });
  });

  it("gracefully falls back on pricing failure", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    ctx.host.http.request.mockImplementation((opts) => {
      if (opts.url === "https://crof.ai/usage_api/") {
        return { status: 200, headers: {}, bodyText: JSON.stringify({ usable_requests: 500, credits: 10 }) };
      }
      return { status: 403, headers: {}, bodyText: "" };
    });
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[0]).toMatchObject({ label: "Requests", limit: 15000 });
    expect(result.plan).toBeNull();
  });

  // ---- Content lines ----

  it("shows credits and tokens", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines[1]).toMatchObject({ label: "Credits", value: "$42.50" });
    expect(result.lines[2]).toMatchObject({ label: "Total tokens", value: "1.3B" });
  });

  it("shows model details", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    var models = result.lines.slice(3);
    expect(models.length).toBe(5);
    expect(models[0].label).toBe("deepseek-v4-pro");
  });

  it("limits to 5 models", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    var many = {};
    for (var i = 0; i < 10; i++) many["m-" + i] = { total_tokens: (10 - i) * 1000 };
    mockHttp(ctx, { userUsageBody: JSON.stringify(many) });
    var plugin = await loadPlugin();
    expect(plugin.probe(ctx).lines.slice(3).length).toBe(5);
  });

  it("sorts models descending", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "s");
    mockHttp(ctx, { userUsageBody: JSON.stringify({ a: { total_tokens: 100 }, b: { total_tokens: 500 } }) });
    var plugin = await loadPlugin();
    var models = plugin.probe(ctx).lines.slice(3);
    expect(models[0].label).toBe("b");
    expect(models[1].label).toBe("a");
  });

  // ---- Session key sources ----

  it("reads session key from file", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setSessionKeyFile(ctx, "file-session");
    mockHttp(ctx);
    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);
    expect(result.plan).toBe("Intermediate");
  });

  it("env var takes priority over file", async () => {
    var ctx = makeCtx();
    setEnv(ctx, API_KEY_ENV, "k");
    setEnv(ctx, SESSION_KEY_ENV, "env-session");
    setSessionKeyFile(ctx, "file-session");
    mockHttp(ctx);
    var plugin = await loadPlugin();

    var calls = ctx.host.http.request.mock.calls;
    for (var i = 0; i < calls.length; i++) {
      var opts = calls[i][0];
      if (opts.url === "https://crof.ai/pricing_api") {
        expect(opts.headers.Cookie).toBe("session=env-session");
      }
    }
  });
});
