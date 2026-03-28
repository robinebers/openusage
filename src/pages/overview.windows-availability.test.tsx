import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { OverviewPage } from "@/pages/overview"

describe("OverviewPage Windows availability", () => {
  it("replaces generic missing-login errors with supported-on-Windows guidance", () => {
    render(
      <OverviewPage
        displayMode="used"
        resetTimerDisplayMode="relative"
        plugins={[
          {
            meta: { id: "claude", name: "Claude", iconUrl: "icon", lines: [], primaryCandidates: [] },
            data: null,
            loading: false,
            error: "Not logged in. Run `claude` to authenticate.",
            lastManualRefreshAt: null,
          },
        ]}
      />
    )

    expect(screen.getByText("Supported on Windows")).toBeInTheDocument()
    expect(screen.getByText(/\.claude\/\.credentials\.json/)).toBeInTheDocument()
    expect(screen.queryByText(/Run `claude` to authenticate\./)).not.toBeInTheDocument()
  })

  it("shows planned Windows messaging for deferred providers", () => {
    render(
      <OverviewPage
        displayMode="used"
        resetTimerDisplayMode="relative"
        plugins={[
          {
            meta: { id: "amp", name: "Amp", iconUrl: "icon", lines: [], primaryCandidates: [] },
            data: null,
            loading: false,
            error: "Not logged in.",
            lastManualRefreshAt: null,
          },
        ]}
      />
    )

    expect(screen.getByText("Planned for Windows")).toBeInTheDocument()
    expect(screen.getByText(/Unix-only local data layout/)).toBeInTheDocument()
    expect(screen.queryByText("Not logged in.")).not.toBeInTheDocument()
  })
})
