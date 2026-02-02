import { render, screen, within } from "@testing-library/react"
import type { ReactNode } from "react"
import userEvent from "@testing-library/user-event"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ProviderCard, formatNumber, formatProgressValue, getProgressPercent } from "@/components/provider-card"
import { REFRESH_COOLDOWN_MS } from "@/lib/settings"

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

describe("ProviderCard", () => {
  beforeEach(() => {
    vi.useRealTimers()
  })

  it("renders error state with retry", async () => {
    const onRetry = vi.fn()
    render(
      <ProviderCard
        name="Test"
        iconUrl="icon"
        error="Nope"
        onRetry={onRetry}
      />
    )
    expect(screen.getByText("Nope")).toBeInTheDocument()
    await userEvent.click(screen.getByText("Retry"))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it("renders loading skeleton", () => {
    render(
      <ProviderCard
        name="Test"
        iconUrl="icon"
        loading
        skeletonLines={[
          { type: "text", label: "One" },
          { type: "badge", label: "Two" },
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
        iconUrl="icon"
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
        iconUrl="icon"
        lines={[
          { type: "text", label: "Label", value: "Value" },
          { type: "badge", label: "Plan", text: "Pro" },
          { type: "progress", label: "Percent", value: 32.4, max: 100, unit: "percent" },
          { type: "progress", label: "Dollars", value: 12.34, max: 100, unit: "dollars" },
          { type: "unknown", label: "Ignored" } as any,
        ]}
      />
    )
    expect(screen.getByText("Label")).toBeInTheDocument()
    expect(screen.getByText("Pro")).toBeInTheDocument()
    expect(screen.getByText("32%")).toBeInTheDocument()
    expect(screen.getByText("$12.34")).toBeInTheDocument()
  })

  it("shows cooldown hint", () => {
    vi.useFakeTimers()
    const now = new Date("2026-02-02T00:00:00.000Z")
    vi.setSystemTime(now)
    const lastManualRefreshAt = now.getTime() - (REFRESH_COOLDOWN_MS - 65_000)
    render(
      <ProviderCard
        name="Cooldown"
        iconUrl="icon"
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
        iconUrl="icon"
        lastManualRefreshAt={lastManualRefreshAt}
        onRetry={() => {}}
      />
    )
    expect(screen.getByText("Available in 30s")).toBeInTheDocument()
    vi.useRealTimers()
  })

  it("renders invalid progress as N/A", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    render(
      <ProviderCard
        name="Invalid"
        iconUrl="icon"
        lines={[
          { type: "progress", label: "Bad", value: -1, max: 100 },
        ]}
      />
    )
    expect(screen.getByText("N/A")).toBeInTheDocument()
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it("formats numbers and progress helpers", () => {
    expect(formatNumber(Number.NaN)).toBe("0")
    expect(formatNumber(5)).toBe("5")
    expect(formatNumber(5.129)).toBe("5.13")
    expect(formatProgressValue(33.2, "percent")).toBe("33%")
    expect(formatProgressValue(1.234, "dollars")).toBe("$1.23")
    expect(formatProgressValue(1.234)).toBe("1.23")
    expect(formatProgressValue(-1)).toBe("N/A")
    expect(getProgressPercent(5, 10)).toBe(50)
    expect(getProgressPercent(5, 0)).toBe(0)
  })

  it("fires retry from header button", () => {
    const onRetry = vi.fn()
    const { container } = render(
      <ProviderCard
        name="Retry"
        iconUrl="icon"
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
        iconUrl="icon"
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
        iconUrl="icon"
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
        iconUrl="icon"
        showSeparator={false}
        lines={[{ type: "text", label: "Label", value: "Value" }]}
      />
    )
    expect(within(container).queryAllByRole("separator")).toHaveLength(0)
  })
})
