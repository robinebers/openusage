import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { PanelFooter } from "@/components/panel-footer"

describe("PanelFooter", () => {
  it("fires refresh when enabled", async () => {
    const onRefresh = vi.fn()
    render(<PanelFooter version="0.0.0" onRefresh={onRefresh} />)
    await userEvent.click(screen.getByText("Refresh all"))
    expect(onRefresh).toHaveBeenCalledTimes(1)
  })

  it("renders disabled refresh state", () => {
    render(<PanelFooter version="0.0.0" onRefresh={() => {}} refreshDisabled />)
    const buttons = screen.getAllByRole("button", { name: "Refresh all" })
    const disabledButton = buttons.find((button) => button.getAttribute("tabindex") === "-1")
    expect(disabledButton).toBeTruthy()
  })
})
