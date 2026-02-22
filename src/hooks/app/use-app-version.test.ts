import { renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

const { getVersionMock } = vi.hoisted(() => ({
  getVersionMock: vi.fn(),
}))

vi.mock("@tauri-apps/api/app", () => ({
  getVersion: getVersionMock,
}))

import { useAppVersion } from "@/hooks/app/use-app-version"

describe("useAppVersion", () => {
  beforeEach(() => {
    getVersionMock.mockReset()
  })

  it("loads app version", async () => {
    getVersionMock.mockResolvedValueOnce("1.2.3")

    const { result } = renderHook(() => useAppVersion())

    expect(result.current).toBe("...")
    await waitFor(() => expect(result.current).toBe("1.2.3"))
  })

  it("logs error and keeps placeholder when version loading fails", async () => {
    const error = new Error("version unavailable")
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    getVersionMock.mockRejectedValueOnce(error)

    const { result } = renderHook(() => useAppVersion())

    await waitFor(() => {
      expect(errorSpy).toHaveBeenCalledWith("Failed to get app version:", error)
    })
    expect(result.current).toBe("...")

    errorSpy.mockRestore()
  })
})
