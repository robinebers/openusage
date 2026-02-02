import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { PanelHeader } from "@/components/panel-header"

describe("PanelHeader", () => {
  it("switches tabs", async () => {
    const onTabChange = vi.fn()
    render(<PanelHeader activeTab="overview" onTabChange={onTabChange} />)
    await userEvent.click(screen.getByText("Settings"))
    expect(onTabChange).toHaveBeenCalledWith("settings")
  })
})
