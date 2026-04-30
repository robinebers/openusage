import { describe, expect, it } from "vitest"

import { getTrayPrimaryBars } from "@/lib/tray-primary-progress"

describe("getTrayPrimaryBars", () => {
  it("returns empty when settings missing", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [],
      pluginSettings: null,
      pluginStates: {},
    })
    expect(bars).toEqual([])
  })

  it("keeps plugin order, filters disabled, limits to 4", () => {
    const pluginsMeta = ["a", "b", "c", "d", "e"].map((id) => ({
      id,
      name: id.toUpperCase(),
      iconUrl: "",
      primaryCandidates: ["Usage"],
      lines: [],
    }))

    const bars = getTrayPrimaryBars({
      pluginsMeta,
      pluginSettings: { order: ["a", "b", "c", "d", "e"], disabled: ["c"] },
      pluginStates: {},
    })

    expect(bars.map((b) => b.id)).toEqual(["a", "b", "d", "e"])
  })

  it("can target a specific plugin id for tray rendering", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [],
        },
        {
          id: "b",
          name: "B",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a", "b"], disabled: [] },
      pluginStates: {
        b: {
          data: {
            providerId: "b",
            displayName: "B",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Session",
                used: 25,
                limit: 100,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
      pluginId: "b",
    })

    expect(bars).toEqual([{ id: "b", label: "Session", fraction: 0.75, warningSeverity: "none" }])
  })

  it("includes plugins with primary candidates even when no data (fraction undefined)", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: { a: { data: null, loading: false, error: null } },
    })
    expect(bars).toEqual([{ id: "a", label: undefined, fraction: undefined, warningSeverity: "none" }])
  })

  it("computes fraction from matching progress label and clamps 0..1", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Plan usage"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Plan usage",
                used: 150,
                limit: 100,
                format: { kind: "dollars" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    expect(bars).toEqual([{ id: "a", label: "Plan usage", fraction: 1, warningSeverity: "none" }])
  })

  it("does not compute fraction when limit is 0", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Plan usage"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Plan usage",
                used: 10,
                limit: 0,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })
    expect(bars).toEqual([{ id: "a", label: "Plan usage", fraction: undefined, warningSeverity: "none" }])
  })

  it("respects displayMode=left", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "left",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Session",
                used: 25,
                limit: 100,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })
    expect(bars).toEqual([{ id: "a", label: "Session", fraction: 0.75, warningSeverity: "none" }])
  })

  it("picks first available candidate from primaryCandidates", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Credits", "Plan usage"], // Credits first, Plan usage fallback
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              // Only Plan usage available, Credits missing
              {
                type: "progress",
                label: "Plan usage",
                used: 50,
                limit: 100,
                format: { kind: "dollars" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })
    expect(bars).toEqual([{ id: "a", label: "Plan usage", fraction: 0.5, warningSeverity: "none" }])
  })

  it("uses first candidate when both are available", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Credits", "Plan usage"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Credits",
                used: 20,
                limit: 100,
                format: { kind: "dollars" },
              },
              {
                type: "progress",
                label: "Plan usage",
                used: 80,
                limit: 100,
                format: { kind: "dollars" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })
    // Should use Credits (20/100 = 0.2), not Plan usage (80/100 = 0.8)
    expect(bars).toEqual([{ id: "a", label: "Credits", fraction: 0.2, warningSeverity: "none" }])
  })

  it("switches from session to weekly when weekly remaining reaches the warning threshold", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "left",
      weeklyWarningThresholdPercent: 30,
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [
            { type: "progress", label: "Session", scope: "overview" },
            { type: "progress", label: "Weekly", scope: "overview" },
          ],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Session",
                used: 25,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "Weekly",
                used: 75,
                limit: 100,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    expect(bars).toEqual([{ id: "a", label: "Weekly", fraction: 0.25, warningSeverity: "warning" }])
  })

  it("marks severe weekly depletion as critical", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "left",
      weeklyWarningThresholdPercent: 30,
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [
            { type: "progress", label: "Session", scope: "overview" },
            { type: "progress", label: "Weekly", scope: "overview" },
          ],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Session",
                used: 5,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "Weekly",
                used: 90,
                limit: 100,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    expect(bars).toEqual([{ id: "a", label: "Weekly", fraction: 0.1, warningSeverity: "critical" }])
  })

  it("skips plugins with empty primaryCandidates", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: [],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {},
    })
    expect(bars).toEqual([])
  })
})
