import { fireEvent, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"
import { openUrl } from "@tauri-apps/plugin-opener"
import { invoke } from "@tauri-apps/api/core"

import { SideNav } from "@/components/side-nav"

const darkModeState = vi.hoisted(() => ({
  useDarkModeMock: vi.fn(() => false),
}))

vi.mock("@/hooks/use-dark-mode", () => ({
  useDarkMode: darkModeState.useDarkModeMock,
}))

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: vi.fn(() => Promise.resolve()),
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(() => Promise.resolve()),
}))

describe("SideNav", () => {
  it("calls onViewChange for Home and Settings", async () => {
    const onViewChange = vi.fn()
    render(<SideNav activeView="home" onViewChange={onViewChange} plugins={[]} />)

    await userEvent.click(screen.getByRole("button", { name: "Settings" }))
    expect(onViewChange).toHaveBeenCalledWith("settings")

    await userEvent.click(screen.getByRole("button", { name: "Home" }))
    expect(onViewChange).toHaveBeenCalledWith("home")
  })

  it("renders plugin icon button and uses brand color when appropriate", () => {
    const onViewChange = vi.fn()
    render(
      <SideNav
        activeView="home"
        onViewChange={onViewChange}
        plugins={[
          { id: "p1", name: "Plugin 1", iconUrl: "icon.svg", brandColor: "#ff0000" },
        ]}
      />
    )

    const btn = screen.getByRole("button", { name: "Plugin 1" })
    expect(btn).toBeInTheDocument()

    const icon = screen.getByRole("img", { name: "Plugin 1" })
    expect(icon).toHaveStyle({ backgroundColor: "#ff0000" })
  })

  it("falls back to currentColor (light) or white (dark) for low-contrast brand colors", () => {
    const onViewChange = vi.fn()

    // Light mode + very light color => currentColor
    darkModeState.useDarkModeMock.mockReturnValueOnce(false)
    const { rerender } = render(
      <SideNav
        activeView="home"
        onViewChange={onViewChange}
        plugins={[{ id: "p", name: "P", iconUrl: "icon.svg", brandColor: "#ffffff" }]}
      />
    )
    const pStyle = screen.getByRole("img", { name: "P" }).getAttribute("style") ?? ""
    expect(pStyle).toMatch(/background-color:\s*currentcolor/i)

    // Dark mode + very dark color => white
    darkModeState.useDarkModeMock.mockReturnValueOnce(true)
    rerender(
      <SideNav
        activeView="home"
        onViewChange={onViewChange}
        plugins={[{ id: "p2", name: "P2", iconUrl: "icon.svg", brandColor: "#000000" }]}
      />
    )
    const p2Style = screen.getByRole("img", { name: "P2" }).getAttribute("style") ?? ""
    expect(p2Style).toContain("rgb(255, 255, 255)")
  })

  it("opens the issues page and hides the panel from Help", async () => {
    const onViewChange = vi.fn()
    render(<SideNav activeView="home" onViewChange={onViewChange} plugins={[]} />)

    await userEvent.click(screen.getByRole("button", { name: "Help" }))

    expect(openUrl).toHaveBeenCalledWith("https://github.com/robinebers/openusage/issues")
    expect(invoke).toHaveBeenCalledWith("hide_panel")
  })

  it("uses non-interactive sidebar chrome as a window drag region", () => {
    const onViewChange = vi.fn()
    const onDragRegionMouseDown = vi.fn()
    const { container } = render(
      <SideNav
        activeView="home"
        onViewChange={onViewChange}
        plugins={[{ id: "p", name: "P", iconUrl: "icon.svg" }]}
        onDragRegionMouseDown={onDragRegionMouseDown}
      />
    )

    const nav = container.querySelector("nav")
    expect(nav).not.toBeNull()

    fireEvent.mouseDown(nav!)
    expect(onDragRegionMouseDown).toHaveBeenCalledTimes(1)

    const homeButton = screen.getByRole("button", { name: "Home" })
    const homeIconPath = homeButton.querySelector("path")
    expect(homeIconPath).not.toBeNull()

    fireEvent.mouseDown(homeIconPath!)
    fireEvent.mouseDown(screen.getByRole("button", { name: "P" }))
    expect(onDragRegionMouseDown).toHaveBeenCalledTimes(1)
  })

  it("calls the drag handler once from the sidebar spacer", () => {
    const onViewChange = vi.fn()
    const onDragRegionMouseDown = vi.fn()
    const { container } = render(
      <SideNav
        activeView="home"
        onViewChange={onViewChange}
        plugins={[]}
        onDragRegionMouseDown={onDragRegionMouseDown}
      />
    )

    const nav = container.querySelector("nav")
    const spacer = Array.from(nav?.children ?? []).find((child) =>
      child.classList.contains("flex-1")
    )
    expect(spacer).toBeDefined()

    fireEvent.mouseDown(spacer!)

    expect(onDragRegionMouseDown).toHaveBeenCalledTimes(1)
  })
})
