import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { AboutDialog } from "@/components/about-dialog"

const openerState = vi.hoisted(() => ({
  openUrlMock: vi.fn(() => Promise.resolve()),
}))

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: openerState.openUrlMock,
}))

describe("AboutDialog", () => {
  it("renders version, links, and maintainers", () => {
    render(<AboutDialog version="1.2.3" onClose={() => {}} />)
    expect(screen.getByText("OpenUsage")).toBeInTheDocument()
    expect(screen.getByText("v1.2.3")).toBeInTheDocument()
    expect(screen.getByText("GitHub")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "validatedev" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "davidarny" })).toBeInTheDocument()
  })

  it("opens maintainer GitHub profiles on click", async () => {
    render(<AboutDialog version="1.2.3" onClose={() => {}} />)

    await userEvent.click(screen.getByRole("button", { name: "validatedev" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith("https://github.com/validatedev")

    openerState.openUrlMock.mockClear()
    await userEvent.click(screen.getByRole("button", { name: "davidarny" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith("https://github.com/davidarny")
  })

  it("closes on Escape", async () => {
    const onClose = vi.fn()
    render(<AboutDialog version="1.2.3" onClose={onClose} />)
    await userEvent.keyboard("{Escape}")
    expect(onClose).toHaveBeenCalled()
  })

  it("does not close on other keys", async () => {
    const onClose = vi.fn()
    render(<AboutDialog version="1.2.3" onClose={onClose} />)
    await userEvent.keyboard("{Enter}")
    expect(onClose).not.toHaveBeenCalled()
  })

  it("closes on backdrop click only", async () => {
    const onClose = vi.fn()
    const { container } = render(<AboutDialog version="1.2.3" onClose={onClose} />)
    const backdrop = container.firstElementChild as HTMLElement
    await userEvent.click(backdrop)
    expect(onClose).toHaveBeenCalledTimes(1)

    // Clicking inside the dialog should not close.
    onClose.mockClear()
    await userEvent.click(screen.getByText("OpenUsage"))
    expect(onClose).not.toHaveBeenCalled()
  })

  it("calls openUrl and logs errors on failure", async () => {
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    openerState.openUrlMock.mockImplementationOnce(() => Promise.reject(new Error("fail")))

    render(<AboutDialog version="1.2.3" onClose={() => {}} />)
    await userEvent.click(screen.getByRole("button", { name: "GitHub" }))

    expect(openerState.openUrlMock).toHaveBeenCalled()
    // wait microtask for catch
    await Promise.resolve()
    expect(consoleSpy).toHaveBeenCalled()

    consoleSpy.mockRestore()
  })

  it("closes when document becomes hidden", () => {
    const onClose = vi.fn()
    render(<AboutDialog version="1.2.3" onClose={onClose} />)

    const original = Object.getOwnPropertyDescriptor(document, "hidden")
    Object.defineProperty(document, "hidden", { value: true, configurable: true })
    document.dispatchEvent(new Event("visibilitychange"))
    expect(onClose).toHaveBeenCalled()

    if (original) {
      Object.defineProperty(document, "hidden", original)
    }
  })

  it("does not close on visibilitychange when document is visible", () => {
    const onClose = vi.fn()
    render(<AboutDialog version="1.2.3" onClose={onClose} />)

    const original = Object.getOwnPropertyDescriptor(document, "hidden")
    Object.defineProperty(document, "hidden", { value: false, configurable: true })
    document.dispatchEvent(new Event("visibilitychange"))
    expect(onClose).not.toHaveBeenCalled()

    if (original) {
      Object.defineProperty(document, "hidden", original)
    }
  })
})

