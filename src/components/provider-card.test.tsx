import { fireEvent, render, screen, within } from "@testing-library/react"
import type { ReactNode } from "react"
import userEvent from "@testing-library/user-event"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { openUrl } from "@tauri-apps/plugin-opener"
import { ProviderCard } from "@/components/provider-card"
import { groupLinesByType } from "@/lib/group-lines-by-type"
import { REFRESH_COOLDOWN_MS } from "@/lib/settings"
import { formatFixedPrecisionNumber } from "@/lib/utils"

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: vi.fn(() => Promise.resolve()),
}))

vi.mock("@/components/ui/tooltip", () => ({
  Tooltip: ({ children }: { children: ReactNode }) => <div>{children}</div>,
  TooltipTrigger: ({
    children,
    render,
    ...props
  }: {
    children: ReactNode
    render?: ((props: Record<string, unknown>) => ReactNode) | ReactNode
  }) => {
    if (typeof render === "function") {
      return render({ ...props, children })
    }
    if (render) return render
    return <div {...props}>{children}</div>
  },
  TooltipContent: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}))

function getEnglishOrdinalSuffix(day: number): string {
  const mod100 = day % 100
  if (mod100 >= 11 && mod100 <= 13) return "th"
  const mod10 = day % 10
  if (mod10 === 1) return "st"
  if (mod10 === 2) return "nd"
  if (mod10 === 3) return "rd"
  return "th"
}

function formatOrdinalDate(date: Date): string {
  const monthText = new Intl.DateTimeFormat(undefined, {
    month: "short",
  }).format(date)
  const day = date.getDate()
  return `${monthText} ${day}${getEnglishOrdinalSuffix(day)}`
}

describe("ProviderCard", () => {
  beforeEach(() => {
    vi.useRealTimers()
    vi.mocked(openUrl).mockClear()
  })

  it("renders error state with retry", async () => {
    const onRetry = vi.fn()
    render(
      <ProviderCard
        name="Test"
        displayMode="used"
        error="Nope"
        onRetry={onRetry}
      />
    )
    expect(screen.getByText("Nope")).toBeInTheDocument()
    await userEvent.click(screen.getByRole("button", { name: "Retry" }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it("renders loading skeleton", () => {
    render(
      <ProviderCard
        name="Test"
        displayMode="used"
        loading
        skeletonLines={[
          { type: "text", label: "One", scope: "overview" },
          { type: "badge", label: "Two", scope: "overview" },
        ]}
      />
    )
    expect(screen.getByText("One")).toBeInTheDocument()
    expect(screen.getByText("Two")).toBeInTheDocument()
  })

  it("shows loading spinner when retry is enabled", () => {
    const { container } = render(
      <ProviderCard
        name="Loading"
        displayMode="used"
        loading
        onRetry={() => {}}
      />
    )
    expect(container.querySelector("svg.animate-spin")).toBeTruthy()
  })

  it("renders metric lines + progress formats", () => {
    render(
      <ProviderCard
        name="Metrics"
        displayMode="used"
        lines={[
          { type: "text", label: "Label", value: "Value" },
          { type: "badge", label: "Plan", text: "Pro" },
          { type: "progress", label: "Percent", used: 32.4, limit: 100, format: { kind: "percent" } },
          { type: "progress", label: "Dollars", used: 12.34, limit: 100, format: { kind: "dollars" } },
          { type: "progress", label: "Credits", used: 342, limit: 1000, format: { kind: "count", suffix: "credits" } },
          { type: "unknown", label: "Ignored" } as any,
        ]}
      />
    )
    expect(screen.getByText("Label")).toBeInTheDocument()
    expect(screen.getByText("Pro")).toBeInTheDocument()
    expect(screen.getByText("32%")).toBeInTheDocument()
    expect(screen.getByText("$12.34")).toBeInTheDocument()
    expect(screen.getByText("342 credits")).toBeInTheDocument()
  })

  it("renders quick links and opens URL", async () => {
    render(
      <ProviderCard
        name="Links"
        displayMode="used"
        links={[
          { label: "Status", url: "https://status.example.com" },
          { label: "Billing", url: "https://example.com/billing" },
        ]}
      />
    )

    await userEvent.click(screen.getByRole("button", { name: /status/i }))
    expect(openUrl).toHaveBeenCalledWith("https://status.example.com")
    expect(screen.getByRole("button", { name: /billing/i })).toBeInTheDocument()
  })

  it("hides invalid links", () => {
    render(
      <ProviderCard
        name="Links"
        displayMode="used"
        links={[
          { label: " ", url: "https://status.example.com" },
          { label: "Dashboard", url: "ftp://example.com" },
          { label: "Status", url: "https://status.example.com" },
        ]}
      />
    )

    expect(screen.getByRole("button", { name: /status/i })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /dashboard/i })).toBeNull()
  })

  it("shows cooldown hint", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    const lastManualRefreshAt = now.getTime() - (REFRESH_COOLDOWN_MS - 65_000)
    render(
      <ProviderCard
        name="Cooldown"
        displayMode="used"
        lastManualRefreshAt={lastManualRefreshAt}
        onRetry={() => {}}
      />
    )
    expect(screen.getByText("Available in 1m 5s")).toBeInTheDocument()
  })

  it("shows seconds-only cooldown", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    const lastManualRefreshAt = now.getTime() - (REFRESH_COOLDOWN_MS - 30_000)
    render(
      <ProviderCard
        name="Cooldown"
        displayMode="used"
        lastManualRefreshAt={lastManualRefreshAt}
        onRetry={() => {}}
      />
    )
    expect(screen.getByText("Available in 30s")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("formats fixed-precision numbers with trailing zeros", () => {
    expect(formatFixedPrecisionNumber(Number.NaN)).toBe("0")
    expect(formatFixedPrecisionNumber(5)).toBe("5")
    expect(formatFixedPrecisionNumber(5.129)).toBe("5.13")
    expect(formatFixedPrecisionNumber(5.1)).toBe("5.10")
    expect(formatFixedPrecisionNumber(5.5)).toBe("5.50")
    expect(formatFixedPrecisionNumber(1000)).toBe("1,000")
    expect(formatFixedPrecisionNumber(10000)).toBe("10,000")
    expect(formatFixedPrecisionNumber(1234567.89)).toBe("1,234,567.89")
  })

  it("supports displayMode=left for percent (number + bar fill)", () => {
    render(
      <ProviderCard
        name="Left"
        displayMode="left"
        lines={[
          { type: "progress", label: "Session", used: 42, limit: 100, format: { kind: "percent" } },
        ]}
      />
    )
    expect(screen.getByText("58% left")).toBeInTheDocument()
    expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "58")
  })

  it("uses elapsed-time marker position in displayMode=left", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T18:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Left Pace"
        displayMode="left"
        lines={[
          {
            type: "progress",
            label: "Weekly",
            used: 30,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
        ]}
      />
    )
    const marker = document.querySelector<HTMLElement>('[data-slot="progress-marker"]')
    expect(marker).toBeTruthy()
    expect(marker?.style.left).toBe("25%")
    vi.useRealTimers()
  })

  it("shows resets secondary text when resetsAt is present", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Monthly",
            used: 12.34,
            limit: 100,
            format: { kind: "dollars" },
            resetsAt: "2026-02-02T01:05:00.000Z",
          },
        ]}
      />
    )
    expect(screen.getByText("Resets in 1h 5m")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("shows 'Resets soon' when reset is under 5 minutes away", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Short",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-02T00:04:59.000Z",
          },
        ]}
      />
    )
    expect(screen.getByText("Resets soon")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("keeps standard reset text at exactly 5 minutes", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Boundary",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-02T00:05:00.000Z",
          },
        ]}
      />
    )
    expect(screen.getByText("Resets in 5m")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("shows 'Resets soon' for stale reset timestamps in relative mode", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:06:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Stale Relative",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-02T00:05:00.000Z",
          },
        ]}
      />
    )
    expect(screen.getByText("Resets soon")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("shows 'Resets soon' for stale reset timestamps in absolute mode", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:06:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        resetTimerDisplayMode="absolute"
        lines={[
          {
            type: "progress",
            label: "Stale Absolute",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-02T00:05:00.000Z",
          },
        ]}
      />
    )
    expect(screen.getByText("Resets soon")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("toggles reset timer display mode from reset label", async () => {
    vi.useFakeTimers()
    const now = new Date(2026, 1, 2, 0, 0, 0)
    vi.setSystemTime(now)
    const onToggle = vi.fn()
    const resetsAt = new Date(2026, 1, 2, 1, 5, 0).toISOString()
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        resetTimerDisplayMode="absolute"
        onResetTimerDisplayModeToggle={onToggle}
        lines={[
          {
            type: "progress",
            label: "Monthly",
            used: 12.34,
            limit: 100,
            format: { kind: "dollars" },
            resetsAt,
          },
        ]}
      />
    )
    const resetButton = screen.getByRole("button", { name: /^Resets today at / })
    expect(resetButton).toBeInTheDocument()
    fireEvent.click(resetButton)
    expect(onToggle).toHaveBeenCalledTimes(1)
    vi.useRealTimers()
  })

  it("shows tomorrow context for absolute reset labels", () => {
    vi.useFakeTimers()
    const now = new Date(2026, 1, 2, 20, 0, 0)
    const resetsAt = new Date(2026, 1, 3, 9, 30, 0)
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        resetTimerDisplayMode="absolute"
        lines={[
          {
            type: "progress",
            label: "Daily",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: resetsAt.toISOString(),
          },
        ]}
      />
    )
    expect(screen.getByText(/^Resets tomorrow at /)).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("shows short date context for absolute labels within a week", () => {
    vi.useFakeTimers()
    const now = new Date(2026, 1, 2, 10, 0, 0)
    const resetsAt = new Date(2026, 1, 5, 16, 0, 0)
    vi.setSystemTime(now)
    const dateText = formatOrdinalDate(resetsAt)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        resetTimerDisplayMode="absolute"
        lines={[
          {
            type: "progress",
            label: "Weekly",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: resetsAt.toISOString(),
          },
        ]}
      />
    )
    expect(
      screen.getByText((content) => content.startsWith(`Resets ${dateText} at `))
    ).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("shows short date context for absolute labels beyond a week", () => {
    vi.useFakeTimers()
    const now = new Date(2026, 1, 2, 10, 0, 0)
    const resetsAt = new Date(2026, 1, 20, 16, 0, 0)
    vi.setSystemTime(now)
    const dateText = formatOrdinalDate(resetsAt)
    render(
      <ProviderCard
        name="Resets"
        displayMode="used"
        resetTimerDisplayMode="absolute"
        lines={[
          {
            type: "progress",
            label: "Monthly",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: resetsAt.toISOString(),
          },
        ]}
      />
    )
    expect(
      screen.getByText((content) => content.startsWith(`Resets ${dateText} at `))
    ).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("shows pace indicators for ahead, on-track, and behind", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T12:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Pace"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Ahead",
            used: 30,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
          {
            type: "progress",
            label: "On Track",
            used: 45,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
          {
            type: "progress",
            label: "Behind",
            used: 60,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
        ]}
      />
    )
    expect(screen.getByLabelText("Plenty of room")).toBeInTheDocument()
    expect(screen.getByLabelText("Right on target")).toBeInTheDocument()
    expect(screen.getByLabelText("Will run out")).toBeInTheDocument()
    expect(screen.getByText("60% used at reset")).toBeInTheDocument()
    expect(screen.getByText("90% used at reset")).toBeInTheDocument()
    expect(screen.getByText("Limit in 8h 0m")).toBeInTheDocument()

    // On-track hides the marker (like CodexBar); only ahead + behind show it
    const markers = document.querySelectorAll<HTMLElement>('[data-slot="progress-marker"]')
    expect(markers).toHaveLength(2)
    expect(markers[0]?.style.left).toBe("50%")
    expect(markers[1]?.style.left).toBe("50%")
    expect(markers[0]).toHaveClass("bg-muted-foreground")
    expect(markers[1]).toHaveClass("bg-muted-foreground")
    vi.useRealTimers()
  })

  it("shows over-limit now detail when already at or above 100%", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T12:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Pace"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Behind",
            used: 120,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
        ]}
      />
    )
    expect(screen.getByLabelText("Limit reached")).toBeInTheDocument()
    expect(screen.getByText("Limit reached")).toBeInTheDocument()
    expect(screen.queryByText(/in deficit/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/runs out in/i)).not.toBeInTheDocument()
    vi.useRealTimers()
  })

  it("hides tiny positive deficit text that would round to zero", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T12:00:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Pace"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Behind",
            used: 50.3,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
        ]}
      />
    )
    expect(screen.getByLabelText("Will run out")).toBeInTheDocument()
    expect(screen.getByText(/^Runs out in /)).toBeInTheDocument()
    expect(screen.queryByText("0% in deficit")).not.toBeInTheDocument()
    expect(screen.queryByText("0% short")).not.toBeInTheDocument()
    expect(screen.queryByText(/in deficit/i)).not.toBeInTheDocument()
    vi.useRealTimers()
  })

  it("keeps status-only tooltip when pace projection is not yet available", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:45:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Pace"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Ahead",
            used: 0,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
        ]}
      />
    )
    expect(screen.getByText("Plenty of room")).toBeInTheDocument()
    expect(screen.queryByText(/at reset/)).not.toBeInTheDocument()
    vi.useRealTimers()
  })

  it("hides marker when pace is unavailable early in period", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:45:00.000Z")
    vi.setSystemTime(now)
    render(
      <ProviderCard
        name="Pace"
        displayMode="used"
        lines={[
          {
            type: "progress",
            label: "Early",
            used: 10,
            limit: 100,
            format: { kind: "percent" },
            resetsAt: "2026-02-03T00:00:00.000Z",
            periodDurationMs: 24 * 60 * 60 * 1000,
          },
        ]}
      />
    )
    expect(screen.queryByLabelText("Plenty of room")).not.toBeInTheDocument()
    expect(document.querySelector('[data-slot="progress-marker"]')).toBeNull()
    vi.useRealTimers()
  })

  it("fires retry from header button", () => {
    const onRetry = vi.fn()
    const { container } = render(
      <ProviderCard
        name="Retry"
        displayMode="used"
        onRetry={onRetry}
        lines={[{ type: "text", label: "Label", value: "Value" }]}
      />
    )
    const buttons = Array.from(container.querySelectorAll("button"))
    const iconButton = buttons.find((button) => button.textContent === "")
    expect(iconButton).toBeTruthy()
    if (iconButton) {
      iconButton.focus()
      iconButton.click()
    }
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it("renders refresh button when cooldown expired", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    const lastManualRefreshAt = now.getTime() - (REFRESH_COOLDOWN_MS + 1000)
    const onRetry = vi.fn()
    const { container } = render(
      <ProviderCard
        name="Retry"
        displayMode="used"
        onRetry={onRetry}
        lastManualRefreshAt={lastManualRefreshAt}
        lines={[{ type: "text", label: "Label", value: "Value" }]}
      />
    )
    const buttons = Array.from(container.querySelectorAll("button"))
    const iconButton = buttons.find((button) => button.textContent === "")
    expect(iconButton).toBeTruthy()
    iconButton?.click()
    expect(onRetry).toHaveBeenCalledTimes(1)
    vi.useRealTimers()
  })

  it("cleans up cooldown timers on unmount", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    const lastManualRefreshAt = now.getTime() - (REFRESH_COOLDOWN_MS - 1000)
    const clearIntervalSpy = vi.spyOn(global, "clearInterval")
    const clearTimeoutSpy = vi.spyOn(global, "clearTimeout")
    const { unmount } = render(
      <ProviderCard
        name="Cooldown"
        displayMode="used"
        lastManualRefreshAt={lastManualRefreshAt}
        onRetry={() => {}}
      />
    )
    unmount()
    expect(clearIntervalSpy).toHaveBeenCalled()
    expect(clearTimeoutSpy).toHaveBeenCalled()
    clearIntervalSpy.mockRestore()
    clearTimeoutSpy.mockRestore()
    vi.useRealTimers()
  })

  it("omits separator when disabled", () => {
    const { container } = render(
      <ProviderCard
        name="NoSep"
        displayMode="used"
        showSeparator={false}
        lines={[{ type: "text", label: "Label", value: "Value" }]}
      />
    )
    expect(within(container).queryAllByRole("separator")).toHaveLength(0)
  })

  it("filters lines by scope=overview", () => {
    render(
      <ProviderCard
        name="Filtered"
        displayMode="used"
        scopeFilter="overview"
        skeletonLines={[
          { type: "text", label: "Primary", scope: "overview" },
          { type: "text", label: "Secondary", scope: "detail" },
        ]}
        lines={[
          { type: "text", label: "Primary", value: "Shown" },
          { type: "text", label: "Secondary", value: "Hidden" },
        ]}
      />
    )
    expect(screen.getByText("Primary")).toBeInTheDocument()
    expect(screen.getByText("Shown")).toBeInTheDocument()
    expect(screen.queryByText("Secondary")).not.toBeInTheDocument()
    expect(screen.queryByText("Hidden")).not.toBeInTheDocument()
  })

  it("shows all lines when scopeFilter=all", () => {
    render(
      <ProviderCard
        name="All"
        displayMode="used"
        scopeFilter="all"
        skeletonLines={[
          { type: "text", label: "Primary", scope: "overview" },
          { type: "text", label: "Secondary", scope: "detail" },
        ]}
        lines={[
          { type: "text", label: "Primary", value: "One" },
          { type: "text", label: "Secondary", value: "Two" },
        ]}
      />
    )
    expect(screen.getByText("Primary")).toBeInTheDocument()
    expect(screen.getByText("One")).toBeInTheDocument()
    expect(screen.getByText("Secondary")).toBeInTheDocument()
    expect(screen.getByText("Two")).toBeInTheDocument()
  })

  it("filters skeleton lines during loading", () => {
    render(
      <ProviderCard
        name="Loading"
        displayMode="used"
        loading
        scopeFilter="overview"
        skeletonLines={[
          { type: "progress", label: "Session", scope: "overview" },
          { type: "progress", label: "Extra", scope: "detail" },
        ]}
      />
    )
    expect(screen.getByText("Session")).toBeInTheDocument()
    expect(screen.queryByText("Extra")).not.toBeInTheDocument()
  })
})

describe("groupLinesByType", () => {
  it("returns empty array for empty input", () => {
    expect(groupLinesByType([])).toEqual([])
  })

  it("groups consecutive text lines together", () => {
    const lines = [
      { type: "text" as const, label: "Today", value: "$0.00" },
      { type: "text" as const, label: "Yesterday", value: "$1.00" },
      { type: "text" as const, label: "Last 30 Days", value: "$5.00" },
    ]
    const groups = groupLinesByType(lines)
    expect(groups).toHaveLength(1)
    expect(groups[0].kind).toBe("text")
    expect(groups[0].lines).toHaveLength(3)
  })

  it("keeps non-text lines as separate 'other' entries", () => {
    const lines = [
      { type: "progress" as const, label: "Session", used: 50, limit: 100, format: { kind: "percent" as const } },
      { type: "progress" as const, label: "Weekly", used: 30, limit: 100, format: { kind: "percent" as const } },
    ]
    const groups = groupLinesByType(lines)
    expect(groups).toHaveLength(1)
    expect(groups[0].kind).toBe("other")
    expect(groups[0].lines).toHaveLength(2)
  })

  it("creates separate groups for alternating text and non-text lines", () => {
    const lines = [
      { type: "progress" as const, label: "Session", used: 50, limit: 100, format: { kind: "percent" as const } },
      { type: "text" as const, label: "Today", value: "$0.00" },
      { type: "text" as const, label: "Yesterday", value: "$1.00" },
      { type: "badge" as const, label: "Status", text: "OK" },
    ]
    const groups = groupLinesByType(lines)
    expect(groups).toHaveLength(3)
    expect(groups[0].kind).toBe("other")
    expect(groups[0].lines).toHaveLength(1)
    expect(groups[1].kind).toBe("text")
    expect(groups[1].lines).toHaveLength(2)
    expect(groups[2].kind).toBe("other")
    expect(groups[2].lines).toHaveLength(1)
  })
})
