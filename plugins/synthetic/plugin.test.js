import { beforeEach, describe, expect, it, vi } from "vitest";
import { makeCtx } from "../test-helpers.js";

const PI_AUTH = "~/.pi/agent/auth.json";
const PI_MODELS = "~/.pi/agent/models.json";
const FACTORY_SETTINGS = "~/.factory/settings.json";
const OC_AUTH = "~/.local/share/opencode/auth.json";
const API_URL = "https://api.synthetic.new/v2/quotas";

const loadPlugin = async () => {
  await import("./plugin.js");
  return globalThis.__openusage_plugin;
};

function setPiAuth(ctx, key, providerName) {
  var obj = {};
  obj[providerName || "synthetic"] = { type: "api_key", key: key };
  ctx.host.fs.writeText(PI_AUTH, JSON.stringify(obj));
}

function setPiModels(ctx, key, providerName) {
  var providers = {};
  providers[providerName || "synthetic"] = { apiKey: key };
  ctx.host.fs.writeText(PI_MODELS, JSON.stringify({ providers: providers }));
}

function setFactorySettings(ctx, apiKey, baseUrl) {
  ctx.host.fs.writeText(
    FACTORY_SETTINGS,
    JSON.stringify({
      customModels: [
        {
          model: "some-model",
          baseUrl: baseUrl || "https://api.synthetic.new/openai/v1",
          apiKey: apiKey,
          displayName: "Test [Synthetic]",
        },
      ],
    })
  );
}

function setOpenCodeAuth(ctx, key, providerName) {
  var obj = {};
  obj[providerName || "synthetic"] = { key: key };
  ctx.host.fs.writeText(OC_AUTH, JSON.stringify(obj));
}

function setEnvKey(ctx, key) {
  ctx.host.env.get.mockImplementation((name) =>
    name === "SYNTHETIC_API_KEY" ? key : null
  );
}

function setEnv(ctx, envValues) {
  ctx.host.env.get.mockImplementation((name) =>
    Object.prototype.hasOwnProperty.call(envValues, name) ? envValues[name] : null
  );
}

function successPayload(overrides) {
  var base = {
    subscription: {
      limit: 600,
      requests: 120,
      renewsAt: "2026-04-30T20:18:54.144Z",
    },
    search: {
      hourly: {
        limit: 250,
        requests: 15,
        renewsAt: "2026-03-30T16:18:54.145Z",
      },
    },
    freeToolCalls: {
      limit: 0,
      requests: 0,
      renewsAt: "2026-03-31T15:18:54.317Z",
    },
    weeklyTokenLimit: {
      nextRegenAt: "2026-03-30T16:20:39.000Z",
      percentRemaining: 75,
    },
    rollingFiveHourLimit: {
      nextTickAt: "2026-03-30T15:30:29.000Z",
      tickPercent: 0.05,
      remaining: 450,
      max: 600,
      limited: false,
    },
  };
  return Object.assign({}, base, overrides);
}

function mockHttp(ctx, payload, status) {
  ctx.host.http.request.mockReturnValue({
    status: status || 200,
    headers: {},
    bodyText: JSON.stringify(payload !== undefined ? payload : successPayload()),
  });
}

describe("synthetic plugin", () => {
  let plugin;

  beforeEach(async () => {
    delete globalThis.__openusage_plugin;
    vi.resetModules();
    plugin = await loadPlugin();
  });

  describe("registration", () => {
    it("registers with correct id", () => {
      expect(plugin.id).toBe("synthetic");
      expect(typeof plugin.probe).toBe("function");
    });
  });

  describe("authentication", () => {
    it("throws when no sources have a key", () => {
      expect(() => plugin.probe(makeCtx())).toThrow(
        "Synthetic API key not found"
      );
    });

    // --- Pi auth.json (source 1) ---

    it("reads key from Pi auth.json", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_piauth");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_piauth");
    });

    it("finds key under alternate provider names in Pi auth.json", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_altname", "synthetic.new");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_altname");
    });

    it("skips Pi auth.json when key is empty", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "  ");
      setEnvKey(ctx, "syn_envkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_envkey");
    });

    it("skips Pi auth.json when invalid JSON", () => {
      var ctx = makeCtx();
      ctx.host.fs.writeText(PI_AUTH, "not json {{{");
      setEnvKey(ctx, "syn_envkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_envkey");
    });

    it("skips Pi auth.json when no matching provider name", () => {
      var ctx = makeCtx();
      ctx.host.fs.writeText(PI_AUTH, JSON.stringify({ other: { key: "sk_other" } }));
      setEnvKey(ctx, "syn_envkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_envkey");
    });

    // --- Pi models.json (source 2) ---

    it("reads key from Pi models.json providers", () => {
      var ctx = makeCtx();
      setPiModels(ctx, "syn_models");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_models");
    });

    it("finds key under alternate provider names in Pi models.json", () => {
      var ctx = makeCtx();
      setPiModels(ctx, "syn_altmodel", "syn");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_altmodel");
    });

    it("Pi auth.json takes precedence over Pi models.json", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_fromauth");
      setPiModels(ctx, "syn_frommodels");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_fromauth");
    });

    // --- PI_CODING_AGENT_DIR override ---

    it("respects PI_CODING_AGENT_DIR for auth.json", () => {
      var ctx = makeCtx();
      setEnv(ctx, { PI_CODING_AGENT_DIR: "~/custom/pi" });
      ctx.host.fs.writeText(
        "~/custom/pi/auth.json",
        JSON.stringify({ synthetic: { type: "api_key", key: "syn_custom" } })
      );
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_custom");
    });

    it("respects PI_CODING_AGENT_DIR for models.json", () => {
      var ctx = makeCtx();
      setEnv(ctx, { PI_CODING_AGENT_DIR: "~/custom/pi" });
      ctx.host.fs.writeText(
        "~/custom/pi/models.json",
        JSON.stringify({ providers: { synthetic: { apiKey: "syn_custommodels" } } })
      );
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_custommodels");
    });

    // --- Factory/Droid settings.json (source 3) ---

    it("reads key from Factory customModels with synthetic.new baseUrl", () => {
      var ctx = makeCtx();
      setFactorySettings(ctx, "syn_factory");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_factory");
    });

    it("matches any baseUrl containing synthetic.new", () => {
      var ctx = makeCtx();
      setFactorySettings(ctx, "syn_custom", "https://custom.synthetic.new/v1");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_custom");
    });

    it("skips Factory models without synthetic.new baseUrl", () => {
      var ctx = makeCtx();
      ctx.host.fs.writeText(
        FACTORY_SETTINGS,
        JSON.stringify({
          customModels: [
            { baseUrl: "https://api.openai.com/v1", apiKey: "sk_other" },
          ],
        })
      );
      setEnvKey(ctx, "syn_envkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_envkey");
    });

    it("Pi sources take precedence over Factory", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_pi");
      setFactorySettings(ctx, "syn_factory");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_pi");
    });

    // --- OpenCode auth.json (source 4) ---

    it("reads key from OpenCode auth.json", () => {
      var ctx = makeCtx();
      setOpenCodeAuth(ctx, "syn_opencode");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_opencode");
    });

    it("Pi sources take precedence over OpenCode", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_pi");
      setOpenCodeAuth(ctx, "syn_oc");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_pi");
    });

    // --- Env var (source 5) ---

    it("falls back to SYNTHETIC_API_KEY env var", () => {
      var ctx = makeCtx();
      setEnvKey(ctx, "syn_envkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_envkey");
    });

    it("file sources take precedence over env var", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_filekey");
      setEnvKey(ctx, "syn_envkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.headers.Authorization).toBe("Bearer syn_filekey");
    });
  });

  describe("HTTP request", () => {
    it("sends correct request", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      plugin.probe(ctx);
      var call = ctx.host.http.request.mock.calls[0][0];
      expect(call.method).toBe("GET");
      expect(call.url).toBe(API_URL);
      expect(call.headers.Authorization).toBe("Bearer syn_testkey");
      expect(call.headers.Accept).toBe("application/json");
      expect(call.timeoutMs).toBe(15000);
    });
  });

  describe("error handling", () => {
    it("throws on network error", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      ctx.host.http.request.mockImplementation(() => {
        throw new Error("ECONNREFUSED");
      });
      expect(() => plugin.probe(ctx)).toThrow("Request failed. Check your connection.");
    });

    it("throws on HTTP 401", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx, {}, 401);
      expect(() => plugin.probe(ctx)).toThrow("API key invalid or expired");
    });

    it("throws on HTTP 403", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx, {}, 403);
      expect(() => plugin.probe(ctx)).toThrow("API key invalid or expired");
    });

    it("throws on HTTP 500", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx, {}, 500);
      expect(() => plugin.probe(ctx)).toThrow("HTTP 500");
    });

    it("uses nested API error messages when the error payload is structured", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx, { error: { message: "Credits required for this feature." } }, 429);
      expect(() => plugin.probe(ctx)).toThrow("Credits required for this feature.");
    });

    it("throws on unparseable JSON", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      ctx.host.http.request.mockReturnValue({
        status: 200,
        headers: {},
        bodyText: "not json",
      });
      expect(() => plugin.probe(ctx)).toThrow("Could not parse usage data");
    });
  });

  describe("5h Rate Limit line", () => {
    it("shows used and limit from API max", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "5h Rate Limit");
      expect(line).toBeTruthy();
      expect(line.type).toBe("progress");
      expect(line.used).toBe(150); // 600 - 450
      expect(line.limit).toBe(600);
      expect(line.format.kind).toBe("count");
      expect(line.format.suffix).toBe("requests");
    });

    it("uses dynamic max, not hardcoded 600", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(
        ctx,
        successPayload({
          rollingFiveHourLimit: {
            nextTickAt: "2026-03-30T15:30:29.000Z",
            tickPercent: 0.05,
            remaining: 300,
            max: 400,
            limited: false,
          },
        })
      );
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "5h Rate Limit");
      expect(line.used).toBe(100); // 400 - 300
      expect(line.limit).toBe(400);
    });

    it("does not include resetsAt (nextTickAt is a partial tick, not a full reset)", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "5h Rate Limit");
      expect(line.resetsAt).toBeUndefined();
      expect(line.periodDurationMs).toBeUndefined();
    });

    it("shows full usage when remaining is 0", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(
        ctx,
        successPayload({
          rollingFiveHourLimit: {
            nextTickAt: "2026-03-30T15:30:29.000Z",
            tickPercent: 0.05,
            remaining: 0,
            max: 600,
            limited: true,
          },
        })
      );
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "5h Rate Limit");
      expect(line.used).toBe(600);
      expect(line.limit).toBe(600);
    });

    it("absent when rollingFiveHourLimit missing", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "5h Rate Limit");
      expect(line).toBeUndefined();
    });
  });

  describe("Mana Bar line", () => {
    it("shows percent used", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Mana Bar");
      expect(line).toBeTruthy();
      expect(line.type).toBe("progress");
      expect(line.used).toBe(25); // 100 - 75
      expect(line.limit).toBe(100);
      expect(line.format.kind).toBe("percent");
    });

    it("used is 0 when percentRemaining is 100", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(
        ctx,
        successPayload({
          weeklyTokenLimit: {
            nextRegenAt: "2026-03-30T16:20:39.000Z",
            percentRemaining: 100,
          },
        })
      );
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Mana Bar");
      expect(line.used).toBe(0);
    });

    it("used is 100 when percentRemaining is 0", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(
        ctx,
        successPayload({
          weeklyTokenLimit: {
            nextRegenAt: "2026-03-30T16:20:39.000Z",
            percentRemaining: 0,
          },
        })
      );
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Mana Bar");
      expect(line.used).toBe(100);
    });

    it("does not include resetsAt (nextRegenAt is a partial regen tick, not a full reset)", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Mana Bar");
      expect(line.resetsAt).toBeUndefined();
      expect(line.periodDurationMs).toBeUndefined();
    });

    it("absent when weeklyTokenLimit missing", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.weeklyTokenLimit;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Mana Bar");
      expect(line).toBeUndefined();
    });
  });

  describe("Rate Limited badge", () => {
    it("absent when limited is false", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var badge = result.lines.find((l) => l.label === "Rate Limited");
      expect(badge).toBeUndefined();
    });

    it("present when limited is true", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(
        ctx,
        successPayload({
          rollingFiveHourLimit: {
            nextTickAt: "2026-03-30T15:30:29.000Z",
            tickPercent: 0.05,
            remaining: 0,
            max: 600,
            limited: true,
          },
        })
      );
      var result = plugin.probe(ctx);
      var badge = result.lines.find((l) => l.label === "Rate Limited");
      expect(badge).toBeTruthy();
      expect(badge.type).toBe("badge");
      expect(badge.color).toBe("#ef4444");
    });

    it("absent when rollingFiveHourLimit missing", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var badge = result.lines.find((l) => l.label === "Rate Limited");
      expect(badge).toBeUndefined();
    });
  });

  describe("Subscription line", () => {
    it("hidden when user is on v3 rate limits", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx); // default payload has both v3 fields and subscription
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Subscription");
      expect(line).toBeUndefined();
    });

    it("shown for legacy users without v3 fields", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      delete payload.weeklyTokenLimit;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Subscription");
      expect(line).toBeTruthy();
      expect(line.type).toBe("progress");
      expect(line.used).toBe(120);
      expect(line.limit).toBe(600);
      expect(line.format.kind).toBe("count");
      expect(line.format.suffix).toBe("requests");
    });

    it("shown when v3 blocks are placeholders without usable numeric fields", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload({
        rollingFiveHourLimit: {},
        weeklyTokenLimit: {},
      });
      payload.freeToolCalls = {
        limit: 500,
        requests: 53.5,
        renewsAt: "2026-03-18T18:12:22.366Z",
      };
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      expect(result.lines.find((l) => l.label === "Subscription")).toBeTruthy();
      expect(result.lines.find((l) => l.label === "Free Tool Calls")).toBeTruthy();
    });

    it("hidden when either v3 quota block is usable", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload({
        rollingFiveHourLimit: {},
      });
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Subscription");
      expect(line).toBeUndefined();
    });

    it("includes resetsAt for legacy users", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      delete payload.weeklyTokenLimit;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Subscription");
      expect(line.resetsAt).toBe("2026-04-30T20:18:54.144Z");
    });

    it("absent when subscription missing", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.subscription;
      delete payload.rollingFiveHourLimit;
      delete payload.weeklyTokenLimit;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Subscription");
      expect(line).toBeUndefined();
    });
  });

  describe("Free Tool Calls line", () => {
    it("hidden when user is on v3 rate limits", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx); // default payload is v3 with freeToolCalls limit: 0
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Free Tool Calls");
      expect(line).toBeUndefined();
    });

    it("shown for legacy users with non-zero limit", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      delete payload.weeklyTokenLimit;
      payload.freeToolCalls = { limit: 500, requests: 53.5, renewsAt: "2026-03-18T18:12:22.366Z" };
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Free Tool Calls");
      expect(line).toBeTruthy();
      expect(line.used).toBe(54); // rounded from 53.5
      expect(line.limit).toBe(500);
      expect(line.format.kind).toBe("count");
      expect(line.format.suffix).toBe("requests");
    });

    it("includes resetsAt for legacy users", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      delete payload.weeklyTokenLimit;
      payload.freeToolCalls = { limit: 500, requests: 0, renewsAt: "2026-03-18T18:12:22.366Z" };
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Free Tool Calls");
      expect(line.resetsAt).toBe("2026-03-18T18:12:22.366Z");
    });

    it("hidden for legacy users when limit is 0", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.rollingFiveHourLimit;
      delete payload.weeklyTokenLimit;
      payload.freeToolCalls = { limit: 0, requests: 0, renewsAt: "2026-03-31T15:18:54.317Z" };
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Free Tool Calls");
      expect(line).toBeUndefined();
    });
  });

  describe("Search line", () => {
    it("shows hourly search count", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Search");
      expect(line).toBeTruthy();
      expect(line.type).toBe("progress");
      expect(line.used).toBe(15);
      expect(line.limit).toBe(250);
      expect(line.format.kind).toBe("count");
      expect(line.format.suffix).toBe("requests");
      expect(line.periodDurationMs).toBe(60 * 60 * 1000);
    });

    it("includes resetsAt from renewsAt", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Search");
      expect(line.resetsAt).toBe("2026-03-30T16:18:54.145Z");
    });

    it("absent when search missing", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      var payload = successPayload();
      delete payload.search;
      mockHttp(ctx, payload);
      var result = plugin.probe(ctx);
      var line = result.lines.find((l) => l.label === "Search");
      expect(line).toBeUndefined();
    });
  });

  describe("full success", () => {
    it("returns all lines in correct order", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(ctx);
      var result = plugin.probe(ctx);
      expect(result.lines.length).toBe(3); // v3 user: no badge, no subscription
      expect(result.lines[0].label).toBe("5h Rate Limit");
      expect(result.lines[1].label).toBe("Mana Bar");
      expect(result.lines[2].label).toBe("Search");
    });

    it("returns 4 lines when rate limited", () => {
      var ctx = makeCtx();
      setPiAuth(ctx, "syn_testkey");
      mockHttp(
        ctx,
        successPayload({
          rollingFiveHourLimit: {
            nextTickAt: "2026-03-30T15:30:29.000Z",
            tickPercent: 0.05,
            remaining: 0,
            max: 600,
            limited: true,
          },
        })
      );
      var result = plugin.probe(ctx);
      expect(result.lines.length).toBe(4); // v3 user rate limited: no subscription
      expect(result.lines[2].label).toBe("Rate Limited");
      expect(result.lines[3].label).toBe("Search");
    });
  });
});
