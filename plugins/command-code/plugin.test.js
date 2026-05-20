import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makePluginTestContext } from "../test-helpers.js";

const AUTH_FILE = "~/.commandcode/auth.json";
const API_BASE = "https://api.commandcode.ai";

const loadPlugin = async () => {
  await import("./plugin.js");
  return globalThis.__openusage_plugin;
};

// Actual API response shapes (probed live from real endpoints)
function makeCreditsResponse(overrides = {}) {
  return {
    credits: {
      belowThreshold: false,
      creditThreshold: 0,
      monthlyCredits: 6.5961,
      purchasedCredits: 0,
      freeCredits: 0,
      ...overrides,
    },
  };
}

function makeUsageSummaryResponse(overrides = {}) {
  return {
    totalCount: 1146,
    totalCost: 3.4101,
    averageCost: 0.00297565445026178,
    successRate: 100,
    completedCount: 1146,
    failedCount: 0,
    totalTokensIn: "43405968",
    totalTokensOut: "364377",
    totalTokens: "43770345",
    totalCredits: 3.4101,
    totalFreeCredits: 0,
    totalMonthlyCredits: 3.4101,
    totalPurchasedCredits: 0,
    models: [
      { model: "deepseek/deepseek-v4-pro", totalCost: 3.1629, count: 1027 },
      { model: "moonshotai/Kimi-K2.5", totalCost: 0.2185, count: 41 },
    ],
    ...overrides,
  };
}

function makeSubscriptionResponse(overrides = {}) {
  return {
    success: true,
    data: {
      id: "sub_abc123",
      status: "active",
      userId: "user_abc",
      orgId: null,
      planId: "individual-go",
      currentPeriodStart: "2026-05-05T05:34:26.000Z",
      currentPeriodEnd: "2026-06-05T05:34:26.000Z",
      ...overrides,
    },
  };
}

function makeWhoamiResponse() {
  return {
    success: true,
    user: {
      id: "bd41f48a-...",
      name: "ec812",
      email: "ec812@me.com",
      userName: "ec812",
    },
    org: null,
  };
}

function mockEndpoints(ctx, credits, usage, sub, extraMatcher) {
  ctx.host.http.request.mockImplementation((opts) => {
    var url = String(opts.url);

    if (opts.method === "GET" && url.includes("/alpha/whoami")) {
      return { status: 200, bodyText: JSON.stringify(makeWhoamiResponse()) };
    }
    if (opts.method === "GET" && url.includes("/alpha/billing/credits")) {
      return { status: 200, bodyText: JSON.stringify(credits) };
    }
    if (opts.method === "GET" && url.includes("/alpha/usage/summary")) {
      return { status: 200, bodyText: JSON.stringify(usage) };
    }
    if (opts.method === "GET" && url.includes("/alpha/billing/subscriptions")) {
      return { status: 200, bodyText: JSON.stringify(sub) };
    }

    if (extraMatcher) return extraMatcher(opts);
    return { status: 500, bodyText: "unexpected: " + url };
  });
}

function setAuth(ctx, apiKey) {
  ctx.host.fs.writeText(
    AUTH_FILE,
    JSON.stringify({
      apiKey: apiKey || "user_test_key_abc123",
      userId: "bd41f48a-f075-4850-b2f4-b251bd841a09",
      userName: "ec812",
    }),
  );
}

describe("command-code plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin;
    vi.resetModules();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it("ships plugin metadata with links and expected line layout", () => {
    var manifest = JSON.parse(
      readFileSync("plugins/command-code/plugin.json", "utf8"),
    );

    expect(manifest.id).toBe("command-code");
    expect(manifest.name).toBe("Command Code");
    expect(manifest.brandColor).toBe("#000000");
    expect(manifest.links).toEqual([
      { label: "Studio", url: "https://commandcode.ai/studio" },
    ]);
    expect(manifest.lines).toEqual([
      { type: "progress", label: "Monthly credits", scope: "overview", primaryOrder: 1 },
      { type: "text", label: "Total spent", scope: "overview" },
      { type: "text", label: "Tokens used", scope: "detail" },
      { type: "text", label: "Models", scope: "detail" },
    ]);
  });

  it("throws when auth file is missing", async () => {
    var ctx = makePluginTestContext();
    var plugin = await loadPlugin();
    expect(function () { plugin.probe(ctx); }).toThrow("Not logged in");
  });

  it("throws when auth file is present but api key is empty", async () => {
    var ctx = makePluginTestContext();
    ctx.host.fs.writeText(AUTH_FILE, JSON.stringify({ apiKey: "", userId: "test" }));
    var plugin = await loadPlugin();
    expect(function () { plugin.probe(ctx); }).toThrow("Not logged in");
  });

  it("throws when API is unreachable", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    ctx.host.http.request.mockImplementation(function () {
      throw new Error("network error");
    });
    var plugin = await loadPlugin();
    expect(function () { plugin.probe(ctx); }).toThrow("Command Code API unreachable");
  });

  it("returns progress bar with correct percentage from real API values", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    mockEndpoints(
      ctx,
      makeCreditsResponse(),   // monthlyCredits: 6.5961 (remaining)
      makeUsageSummaryResponse(), // totalMonthlyCredits: 3.4101 (used)
      makeSubscriptionResponse(),
    );

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    // total plan = 3.4101 + 6.5961 = 10.0062
    // used% = 3.4101 / 10.0062 = 34.1%
    expect(result.plan).toBe("Individual Go");

    var monthlyLine = result.lines.find(function (l) { return l.label === "Monthly credits"; });
    expect(monthlyLine).toBeTruthy();
    expect(monthlyLine.type).toBe("progress");
    expect(Math.round(monthlyLine.used)).toBe(34);

    var spentLine = result.lines.find(function (l) { return l.label === "Total spent"; });
    expect(spentLine).toBeTruthy();
    expect(spentLine.value).toContain("$3.41");
  });

  it("includes Authorization header with bearer token", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx, "my-secret-key");
    mockEndpoints(ctx, makeCreditsResponse(), makeUsageSummaryResponse(), makeSubscriptionResponse());

    var plugin = await loadPlugin();
    plugin.probe(ctx);

    var calls = ctx.host.http.request.mock.calls;
    for (var i = 0; i < calls.length; i++) {
      var headers = calls[i][0].headers;
      expect(headers.Authorization).toBe("Bearer my-secret-key");
    }
  });

  it("shows model breakdown in detail view", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    mockEndpoints(ctx, makeCreditsResponse(), makeUsageSummaryResponse(), makeSubscriptionResponse());

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    var modelsLine = result.lines.find(function (l) { return l.label === "Models"; });
    expect(modelsLine).toBeTruthy();
    expect(modelsLine.value).toContain("deepseek-v4-pro");
    expect(modelsLine.value).toContain("Kimi-K2.5");
  });

  it("handles empty models array gracefully", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    mockEndpoints(
      ctx,
      makeCreditsResponse(),
      makeUsageSummaryResponse({ models: [] }),
      makeSubscriptionResponse(),
    );

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    var modelsLine = result.lines.find(function (l) { return l.label === "Models"; });
    expect(modelsLine).toBeUndefined();

    // Should still show progress and text lines
    expect(result.lines.length).toBeGreaterThanOrEqual(2);
    expect(result.lines[0].type).toBe("progress");
  });

  it("handles API returning empty/minimal responses gracefully", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    // Return empty object for all non-whoami calls
    ctx.host.http.request.mockImplementation(function (opts) {
      var url = String(opts.url);
      if (url.includes("/alpha/whoami")) {
        return { status: 200, bodyText: JSON.stringify(makeWhoamiResponse()) };
      }
      return { status: 200, bodyText: JSON.stringify({}) };
    });

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.lines.length).toBe(0);
    expect(result.plan).toBeNull();
  });

  it("uses COMMAND_CODE_API_KEY env var when auth file is missing", async () => {
    var ctx = makePluginTestContext();
    ctx.host.env.get.mockImplementation(function (name) {
      if (name === "COMMAND_CODE_API_KEY") return "env-override-key";
      return null;
    });
    mockEndpoints(ctx, makeCreditsResponse(), makeUsageSummaryResponse(), makeSubscriptionResponse());

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    expect(result.plan).toBe("Individual Go");
    var calls = ctx.host.http.request.mock.calls;
    var firstCall = calls[0];
    expect(firstCall[0].headers.Authorization).toBe("Bearer env-override-key");
  });

  it("shows token count from usage summary", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    mockEndpoints(ctx, makeCreditsResponse(), makeUsageSummaryResponse(), makeSubscriptionResponse());

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    var tokensLine = result.lines.find(function (l) { return l.label === "Tokens used"; });
    expect(tokensLine).toBeTruthy();
    // 43,770,345 → "44M" tokens
    expect(tokensLine.value).toMatch(/^\d+[KM]?$/);
  });

  it("handles zero totalCost gracefully", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    mockEndpoints(
      ctx,
      makeCreditsResponse(),
      makeUsageSummaryResponse({ totalCost: 0, totalMonthlyCredits: 0, models: [] }),
      makeSubscriptionResponse(),
    );

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    var spentLine = result.lines.find(function (l) { return l.label === "Total spent"; });
    expect(spentLine).toBeUndefined();
  });

  it("clamps usage percentage at 100", async () => {
    var ctx = makePluginTestContext();
    setAuth(ctx);
    // monthlyUsed (12) + creditsRemaining (5) = total plan (17)
    // used% = 12 / 17 = 70.6% — not hitting clamp.
    // To hit clamp, make used >= total plan:
    mockEndpoints(
      ctx,
      makeCreditsResponse({ monthlyCredits: 0 }),  // remaining = 0
      makeUsageSummaryResponse({ totalMonthlyCredits: 15 }), // used = 15
      makeSubscriptionResponse(),
    );

    var plugin = await loadPlugin();
    var result = plugin.probe(ctx);

    var monthlyLine = result.lines.find(function (l) { return l.label === "Monthly credits"; });
    expect(monthlyLine.used).toBe(100);
  });
});
