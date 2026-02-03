import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"
import { PanelFooter } from "@/components/panel-footer"
import type { UpdateStatus } from "@/hooks/use-app-update"

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: vi.fn(() => Promise.resolve()),
}))

const idle: UpdateStatus = { status: "idle" }
const noop = () => {}
const aboutProps = { showAbout: false, onShowAbout: noop, onCloseAbout: noop }

describe("PanelFooter", () => {
  it("shows countdown in minutes when >= 60 seconds", () => {
    const futureTime = Date.now() + 5 * 60 * 1000 // 5 minutes from now
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={futureTime}
        updateStatus={idle}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(screen.getByText("Next update in 5m")).toBeTruthy()
  })

  it("shows countdown in seconds when < 60 seconds", () => {
    const futureTime = Date.now() + 30 * 1000 // 30 seconds from now
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={futureTime}
        updateStatus={idle}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(screen.getByText("Next update in 30s")).toBeTruthy()
  })

  it("shows Paused when autoUpdateNextAt is null", () => {
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={null}
        updateStatus={idle}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(screen.getByText("Paused")).toBeTruthy()
  })

  it("shows downloading state", () => {
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={null}
        updateStatus={{ status: "downloading", progress: 42 }}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(screen.getByText("Downloading update 42%")).toBeTruthy()
  })

  it("shows downloading state without percentage when progress is unknown", () => {
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={null}
        updateStatus={{ status: "downloading", progress: -1 }}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(screen.getByText("Downloading update...")).toBeTruthy()
  })

  it("shows restart button when ready", async () => {
    const onInstall = vi.fn()
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={null}
        updateStatus={{ status: "ready" }}
        onUpdateInstall={onInstall}
        {...aboutProps}
      />
    )
    const button = screen.getByText("Restart to update")
    expect(button).toBeTruthy()
    await userEvent.click(button)
    expect(onInstall).toHaveBeenCalledTimes(1)
  })

  it("shows error state", () => {
    const { container } = render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={null}
        updateStatus={{ status: "error", message: "oops" }}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(container.textContent).toContain("Update failed")
  })

  it("shows installing state", () => {
    render(
      <PanelFooter
        version="0.0.0"
        autoUpdateNextAt={null}
        updateStatus={{ status: "installing" }}
        onUpdateInstall={noop}
        {...aboutProps}
      />
    )
    expect(screen.getByText("Installing...")).toBeTruthy()
  })

  it("opens About dialog when clicking version in idle state", async () => {
    function Harness() {
      const [showAbout, setShowAbout] = useState(false)
      return (
        <PanelFooter
          version="0.0.0"
          autoUpdateNextAt={null}
          updateStatus={idle}
          onUpdateInstall={noop}
          showAbout={showAbout}
          onShowAbout={() => setShowAbout(true)}
          onCloseAbout={() => setShowAbout(false)}
        />
      )
    }

    render(<Harness />)
    await userEvent.click(screen.getByRole("button", { name: /OpenUsage/ }))
    expect(screen.getByText("Open source on")).toBeInTheDocument()

    // Close via Escape to exercise AboutDialog onClose path.
    await userEvent.keyboard("{Escape}")
    expect(screen.queryByText("Open source on")).not.toBeInTheDocument()
  })
})
