import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { PanelFooter } from "@/components/panel-footer"
import type { UpdateStatus } from "@/hooks/use-app-update"

const idle: UpdateStatus = { status: "idle" }
const noop = () => {}

describe("PanelFooter", () => {
  it("fires refresh when enabled", async () => {
    const onRefresh = vi.fn()
    render(
      <PanelFooter
        version="0.0.0"
        onRefresh={onRefresh}
        updateStatus={idle}
        onUpdateDownload={noop}
        onUpdateInstall={noop}
      />
    )
    await userEvent.click(screen.getByText("Refresh all"))
    expect(onRefresh).toHaveBeenCalledTimes(1)
  })

  it("renders disabled refresh state", () => {
    render(
      <PanelFooter
        version="0.0.0"
        onRefresh={noop}
        refreshDisabled
        updateStatus={idle}
        onUpdateDownload={noop}
        onUpdateInstall={noop}
      />
    )
    const buttons = screen.getAllByRole("button", { name: "Refresh all" })
    const disabledButton = buttons.find((button) => button.getAttribute("tabindex") === "-1")
    expect(disabledButton).toBeTruthy()
  })

  it("shows update available link", async () => {
    const onDownload = vi.fn()
    render(
      <PanelFooter
        version="0.0.0"
        onRefresh={noop}
        updateStatus={{ status: "available", version: "1.0.0" }}
        onUpdateDownload={onDownload}
        onUpdateInstall={noop}
      />
    )
    const link = screen.getByText("v1.0.0 available")
    expect(link).toBeTruthy()
    await userEvent.click(link)
    expect(onDownload).toHaveBeenCalledTimes(1)
  })

  it("shows downloading state", () => {
    render(
      <PanelFooter
        version="0.0.0"
        onRefresh={noop}
        updateStatus={{ status: "downloading", progress: 42 }}
        onUpdateDownload={noop}
        onUpdateInstall={noop}
      />
    )
    expect(screen.getByText("Downloading... 42%")).toBeTruthy()
  })

  it("shows restart link when ready", async () => {
    const onInstall = vi.fn()
    render(
      <PanelFooter
        version="0.0.0"
        onRefresh={noop}
        updateStatus={{ status: "ready" }}
        onUpdateDownload={noop}
        onUpdateInstall={onInstall}
      />
    )
    const link = screen.getByText("Restart to update")
    expect(link).toBeTruthy()
    await userEvent.click(link)
    expect(onInstall).toHaveBeenCalledTimes(1)
  })

  it("falls back to version display on error", () => {
    const { container } = render(
      <PanelFooter
        version="0.0.0"
        onRefresh={noop}
        updateStatus={{ status: "error", message: "oops" }}
        onUpdateDownload={noop}
        onUpdateInstall={noop}
      />
    )
    expect(container.textContent).toContain("OpenUsage 0.0.0")
    expect(container.textContent).not.toContain("available")
    expect(container.textContent).not.toContain("Restart")
    expect(container.textContent).not.toContain("Downloading")
  })
})
