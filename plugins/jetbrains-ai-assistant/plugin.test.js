import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const DARWIN_PATH = "~/Library/Application Support/JetBrains/WebStorm2025.3/options/AIAssistantQuotaManager2.xml"
const LINUX_PATH = "~/.config/JetBrains/IntelliJIdea2025.3/options/AIAssistantQuotaManager2.xml"

const loadPlugin = async () => {
  await import("./plugin.js")
  return globalThis.__openusage_plugin
}

function encodeXmlValue(value) {
  return JSON.stringify(value, null, 4)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/\n/g, "&#10;")
}

function makeQuotaXml({ quotaInfo, nextRefill }) {
  return [
    "<application>",
    '  <component name="AIAssistantQuotaManager2">',
    `    <option name="nextRefill" value="${encodeXmlValue(nextRefill)}" />`,
    `    <option name="quotaInfo" value="${encodeXmlValue(quotaInfo)}" />`,
    "  </component>",
    "</application>",
  ].join("\n")
}

describe("jetbrains-ai-assistant plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
    vi.resetModules()
  })

  it("parses quota xml and emits quota + remaining lines", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "75",
          maximum: "100",
          available: "25",
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: {
          type: "Known",
          next: "2099-01-01T00:00:00Z",
          tariff: { amount: "100", duration: "PT720H" },
        },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)

    const quota = result.lines.find((line) => line.label === "Quota")
    const used = result.lines.find((line) => line.label === "Used")
    const remaining = result.lines.find((line) => line.label === "Remaining")

    expect(quota && quota.used).toBe(75)
    expect(quota && quota.limit).toBe(100)
    expect(quota && quota.resetsAt).toBe("2099-01-01T00:00:00.000Z")
    expect(quota && quota.periodDurationMs).toBe(2592000000)
    expect(used && used.value).toBe("75")
    expect(remaining && remaining.value).toBe("25")
  })

  it("falls back to quota until when nextRefill is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "50",
          maximum: "100",
          available: "50",
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: null,
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const quota = result.lines.find((line) => line.label === "Quota")
    expect(quota && quota.resetsAt).toBe("2099-01-31T00:00:00.000Z")
  })

  it("prefers the quota state with the latest until window", async () => {
    const ctx = makeCtx()
    ctx.app.platform = "macos"

    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "10",
          maximum: "100",
          available: "90",
          until: "2099-01-01T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "0", duration: "PT720H" } },
      })
    )

    // Unknown platforms probe all base paths. Write second valid file in Linux path to verify latest-until selection.
    ctx.app.platform = "unknown"
    ctx.host.fs.writeText(
      LINUX_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "20",
          maximum: "100",
          available: "80",
          until: "2099-02-01T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-02-01T00:00:00Z", tariff: { amount: "0", duration: "PT720H" } },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const quota = result.lines.find((line) => line.label === "Quota")
    expect(quota && quota.used).toBe(20)
  })

  it("computes remaining when available is missing", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "60",
          maximum: "100",
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "0", duration: "P30D" } },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const remaining = result.lines.find((line) => line.label === "Remaining")
    expect(remaining && remaining.value).toBe("40")
  })

  it("prefers explicit tariff/topUp available over maximum-current math", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "90",
          maximum: "100",
          // Intentionally inconsistent to verify explicit available is preferred.
          tariffQuota: { current: "90", maximum: "100", available: "12.5" },
          topUpQuota: { current: "0", maximum: "0", available: "3.5" },
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "0", duration: "P30D" } },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const remaining = result.lines.find((line) => line.label === "Remaining")
    expect(remaining && remaining.value).toBe("16")
  })

  it("breaks equal-until ties by higher used ratio", async () => {
    const ctx = makeCtx()
    ctx.app.platform = "unknown"

    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "80",
          maximum: "100",
          available: "20",
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "0", duration: "PT720H" } },
      })
    )
    ctx.host.fs.writeText(
      LINUX_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "30",
          maximum: "100",
          available: "70",
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "0", duration: "PT720H" } },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const used = result.lines.find((line) => line.label === "Used")
    expect(used && used.value).toBe("80")
  })

  it("converts JetBrains raw quota units to credits for display", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "1981684.92",
          maximum: "2367648.941",
          tariffQuota: { current: "1981684.92", maximum: "2367648.941", available: "385964.21" },
          topUpQuota: { current: "0", maximum: "0", available: "0" },
          until: "2026-04-30T21:00:00Z",
        },
        nextRefill: {
          type: "Known",
          next: "2026-03-14T06:00:54.020Z",
          tariff: { amount: "2000000", duration: "PT720H" },
        },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const used = result.lines.find((line) => line.label === "Used")
    const remaining = result.lines.find((line) => line.label === "Remaining")

    expect(used && used.value).toBe("19.82 / 23.68 credits")
    expect(remaining && remaining.value).toBe("3.86 credits")
  })

  it("throws when no quota file is detected", async () => {
    const ctx = makeCtx()
    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("JetBrains AI Assistant not detected")
  })

  it("throws when quota payload is present but invalid", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: {
          type: "Available",
          current: "0",
          maximum: "0",
          until: "2099-01-31T00:00:00Z",
        },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "0", duration: "PT720H" } },
      })
    )

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("quota data unavailable")
  })

  it("discovers quota on windows", async () => {
    const ctx = makeCtx()
    ctx.app.platform = "windows"
    ctx.host.fs.writeText(
      "~/AppData/Roaming/JetBrains/WebStorm2025.3/options/AIAssistantQuotaManager2.xml",
      makeQuotaXml({
        quotaInfo: { current: "50", maximum: "100", available: "50", until: "2099-01-31T00:00:00Z" },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "100", duration: "PT720H" } },
      })
    )

    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const quota = result.lines.find((line) => line.label === "Quota")
    expect(quota && quota.used).toBe(50)
  })

  it("continues gracefully when listDir throws", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(DARWIN_PATH, makeQuotaXml({
      quotaInfo: { current: "50", maximum: "100", available: "50", until: "2099-01-31T00:00:00Z" },
      nextRefill: null,
    }))
    ctx.host.fs.listDir = () => { throw new Error("permission denied") }

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("JetBrains AI Assistant not detected")
  })

  it("throws when quota file exists but quotaInfo element is absent", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      '<application><component name="AIAssistantQuotaManager2"></component></application>'
    )

    const plugin = await loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("quota data unavailable")
  })

  it("parses P30D and P4W durations", async () => {
    const ctx = makeCtx()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: { current: "50", maximum: "100", available: "50", until: "2099-01-31T00:00:00Z" },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "100", duration: "P30D" } },
      })
    )
    const plugin = await loadPlugin()
    const result = plugin.probe(ctx)
    const quota = result.lines.find((line) => line.label === "Quota")
    expect(quota && quota.periodDurationMs).toBe(30 * 24 * 60 * 60 * 1000)

    delete globalThis.__openusage_plugin
    vi.resetModules()
    ctx.host.fs.writeText(
      DARWIN_PATH,
      makeQuotaXml({
        quotaInfo: { current: "50", maximum: "100", available: "50", until: "2099-01-31T00:00:00Z" },
        nextRefill: { type: "Known", next: "2099-01-01T00:00:00Z", tariff: { amount: "100", duration: "P4W" } },
      })
    )
    const plugin2 = await loadPlugin()
    const result2 = plugin2.probe(ctx)
    const quota2 = result2.lines.find((line) => line.label === "Quota")
    expect(quota2 && quota2.periodDurationMs).toBe(4 * 7 * 24 * 60 * 60 * 1000)
  })
})
