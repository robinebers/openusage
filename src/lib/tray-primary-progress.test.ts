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
      primaryProgressLabel: "Usage",
      lines: [],
    }))

    const bars = getTrayPrimaryBars({
      pluginsMeta,
      pluginSettings: { order: ["a", "b", "c", "d", "e"], disabled: ["c"] },
      pluginStates: {},
    })

    expect(bars.map((b) => b.id)).toEqual(["a", "b", "d", "e"])
  })

  it("includes plugins with primary label even when no data (fraction undefined)", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryProgressLabel: "Session",
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: { a: { data: null, loading: false, error: null } },
    })
    expect(bars).toEqual([{ id: "a", fraction: undefined }])
  })

  it("computes fraction from matching progress label and clamps 0..1", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryProgressLabel: "Plan usage",
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

    expect(bars).toEqual([{ id: "a", fraction: 1 }])
  })

  it("does not compute fraction when limit is 0", () => {
    const bars = getTrayPrimaryBars({
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryProgressLabel: "Plan usage",
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
    expect(bars).toEqual([{ id: "a", fraction: undefined }])
  })

  it("respects displayMode=left", () => {
    const bars = getTrayPrimaryBars({
      displayMode: "left",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryProgressLabel: "Session",
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
    expect(bars).toEqual([{ id: "a", fraction: 0.75 }])
  })
})

