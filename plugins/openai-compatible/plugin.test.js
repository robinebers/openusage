import { beforeEach, describe, expect, it, vi } from "vitest";
import { makeCtx } from "../test-helpers.js";

const LEDGER_PATH = "/tmp/openusage-test/openai-compatible-usage.json";

const loadPlugin = async () => {
  await import("./plugin.js");
  return globalThis.__openusage_plugin;
};

function writeLedger(ctx, entries) {
  ctx.host.fs.writeText(LEDGER_PATH, JSON.stringify({ version: 1, entries }));
}

describe("openai-compatible plugin", () => {
  let plugin;

  beforeEach(async () => {
    delete globalThis.__openusage_plugin;
    vi.resetModules();
    plugin = await loadPlugin();
  });

  it("registers with correct id", () => {
    expect(plugin.id).toBe("openai-compatible");
    expect(typeof plugin.probe).toBe("function");
  });

  it("shows setup state when ledger is missing", () => {
    const output = plugin.probe(makeCtx());

    expect(output.providerId).toBe("openai-compatible");
    expect(output.lines[0]).toEqual({
      type: "badge",
      label: "Setup",
      text: "Proxy not used yet",
    });
  });

  it("renders priced usage totals", () => {
    const ctx = makeCtx();
    ctx.nowIso = "2026-06-05T12:00:00.000Z";
    writeLedger(ctx, [
      {
        fetchedAt: "2026-06-05T01:00:00Z",
        model: "gpt-4.1-mini",
        inputTokens: 1000,
        outputTokens: 2000,
        costUsd: 0.004,
        unpriced: false,
        unmetered: false,
      },
    ]);

    const output = plugin.probe(ctx);

    expect(output.lines).toContainEqual({
      type: "text",
      label: "Today",
      value: "$0.0040 · 3K tokens",
    });
    expect(output.lines).toContainEqual({
      type: "text",
      label: "This Month",
      value: "$0.0040 · 3K tokens",
    });
  });

  it("shows unpriced model warning", () => {
    const ctx = makeCtx();
    writeLedger(ctx, [
      {
        fetchedAt: "2026-06-05T01:00:00Z",
        model: "new-model",
        inputTokens: 100,
        outputTokens: 200,
        costUsd: null,
        unpriced: true,
        unmetered: false,
      },
    ]);

    const output = plugin.probe(ctx);

    expect(output.lines).toContainEqual({
      type: "badge",
      label: "Unpriced Models",
      text: "new-model",
      color: "#f59e0b",
    });
  });

  it("shows unmetered request count", () => {
    const ctx = makeCtx();
    writeLedger(ctx, [
      {
        fetchedAt: "2026-06-05T01:00:00Z",
        model: "gpt-4.1-mini",
        inputTokens: 0,
        outputTokens: 0,
        costUsd: null,
        unpriced: false,
        unmetered: true,
      },
    ]);

    const output = plugin.probe(ctx);

    expect(output.lines).toContainEqual({
      type: "badge",
      label: "Unmetered",
      text: "1 request",
      color: "#f59e0b",
    });
  });
});
