import { describe, expect, it } from "vitest"
import { formatResetAbsoluteLabel, formatResetRelativeLabel, formatResetTooltipText } from "@/lib/reset-tooltip"

describe("reset-tooltip", () => {
  it("returns null for invalid reset timestamp", () => {
    expect(
      formatResetTooltipText({
        nowMs: Date.parse("2026-02-03T11:00:00.000Z"),
        resetsAtIso: "not-a-date",
        visibleMode: "relative",
      })
    ).toBeNull()
  })

  it("returns null for invalid direct reset labels", () => {
    const nowMs = Date.parse("2026-02-03T11:00:00.000Z")
    expect(formatResetRelativeLabel(nowMs, "not-a-date")).toBeNull()
    expect(formatResetAbsoluteLabel(nowMs, "not-a-date")).toBeNull()
  })

  it("formats relative reset labels", () => {
    const nowMs = Date.parse("2026-02-03T11:29:00.000Z")
    expect(formatResetRelativeLabel(nowMs, "2026-02-03T12:34:00.000Z")).toBe("Resets in 1h 5m")
  })

  it("formats absolute reset labels with same-day context", () => {
    const nowMs = new Date(2026, 1, 3, 0, 0, 0).getTime()
    const resetsAtIso = new Date(2026, 1, 3, 12, 34, 0).toISOString()
    const timeText = new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
    }).format(Date.parse(resetsAtIso))

    expect(formatResetAbsoluteLabel(nowMs, resetsAtIso)).toBe(`Resets today at ${timeText}`)
  })

  it("formats absolute reset labels with tomorrow context", () => {
    const nowMs = new Date(2026, 1, 3, 22, 0, 0).getTime()
    const resetsAtIso = new Date(2026, 1, 4, 8, 15, 0).toISOString()
    const timeText = new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
    }).format(Date.parse(resetsAtIso))

    expect(formatResetAbsoluteLabel(nowMs, resetsAtIso)).toBe(`Resets tomorrow at ${timeText}`)
  })

  it("formats absolute reset labels with locale-aware month-day context", () => {
    const nowMs = new Date(2026, 0, 28, 9, 0, 0).getTime()
    const cases = [
      new Date(2026, 1, 1, 8, 0, 0).toISOString(),
      new Date(2026, 1, 2, 8, 0, 0).toISOString(),
      new Date(2026, 1, 3, 8, 0, 0).toISOString(),
      new Date(2026, 1, 11, 8, 0, 0).toISOString(),
    ]

    for (const resetsAtIso of cases) {
      const dateText = new Intl.DateTimeFormat(undefined, {
        month: "short",
        day: "numeric",
      }).format(Date.parse(resetsAtIso))

      expect(formatResetAbsoluteLabel(nowMs, resetsAtIso)).toContain(dateText)
    }
  })

  it("shows absolute tooltip text when the visible mode is relative", () => {
    const nowMs = new Date(2026, 1, 3, 0, 0, 0).getTime()
    const resetsAtIso = new Date(2026, 1, 3, 12, 34, 0).toISOString()
    const timeText = new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
    }).format(Date.parse(resetsAtIso))

    expect(
      formatResetTooltipText({
        nowMs,
        resetsAtIso,
        visibleMode: "relative",
      })
    ).toBe(`Resets today at ${timeText}`)
  })

  it("shows relative tooltip text when the visible mode is absolute", () => {
    const nowMs = Date.parse("2026-02-03T11:29:00.000Z")

    expect(
      formatResetTooltipText({
        nowMs,
        resetsAtIso: "2026-02-03T12:34:00.000Z",
        visibleMode: "absolute",
      })
    ).toBe("Resets in 1h 5m")
  })
})
