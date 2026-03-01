import { describe, expect, it } from "vitest"
import { formatResetTooltipText } from "@/lib/reset-tooltip"

describe("reset-tooltip", () => {
  it("returns null for invalid reset timestamp", () => {
    expect(formatResetTooltipText("not-a-date")).toBeNull()
  })

  it("formats reset tooltip content with date and time", () => {
    const resetsAt = "2026-02-03T12:34:00.000Z"
    const expected = new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(Date.parse(resetsAt))

    expect(formatResetTooltipText(resetsAt)).toBe(`Next reset: ${expected}`)
  })
})
