import { afterEach, describe, expect, it, vi } from "vitest"

describe("reset-tooltip mocked branches", () => {
  afterEach(() => {
    vi.doUnmock("@/lib/pace-tooltip")
    vi.resetModules()
  })

  it("returns null when compact duration formatting is unavailable", async () => {
    vi.doMock("@/lib/pace-tooltip", () => ({
      formatCompactDuration: () => null,
    }))

    const { formatResetRelativeLabel } = await import("@/lib/reset-tooltip")

    expect(formatResetRelativeLabel(Date.parse("2026-02-03T11:29:00.000Z"), "2026-02-03T12:34:00.000Z")).toBeNull()
  })
})
