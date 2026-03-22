import { renderHook, waitFor } from "@testing-library/react"
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest"
import { useChangelog, type Release } from "./use-changelog"

describe("useChangelog", () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    globalThis.fetch = vi.fn() as any
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it("fetches release by exact currentVersion tag", async () => {
    const release: Release = {
      id: 1,
      tag_name: "v1.2.3",
      name: "v1.2.3",
      body: "notes",
      published_at: "2024-01-02T00:00:00Z",
      html_url: "https://github.com/robinebers/openusage/releases/tag/v1.2.3",
    }

    const response = {
      ok: true,
      status: 200,
      json: async () => release,
    } as any

    const fetchMock = vi.fn().mockResolvedValue(response)
    globalThis.fetch = fetchMock as any

    const { result } = renderHook(() => useChangelog("v1.2.3"))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.error).toBeNull()
      expect(result.current.releases).toHaveLength(1)
      expect(result.current.releases[0]).toEqual(release)
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.github.com/repos/robinebers/openusage/releases/tags/v1.2.3",
    )
  })

  it("falls back between v-prefixed and non-prefixed tags", async () => {
    const notFoundResponse = {
      ok: false,
      status: 404,
      json: async () => ({}),
    } as any

    const release: Release = {
      id: 2,
      tag_name: "v1.0.0",
      name: "v1.0.0",
      body: "older",
      published_at: "2023-01-01T00:00:00Z",
      html_url: "https://github.com/robinebers/openusage/releases/tag/v1.0.0",
    }

    const okResponse = {
      ok: true,
      status: 200,
      json: async () => release,
    } as any

    const fetchMock = vi
      .fn()
      // first try without v
      .mockResolvedValueOnce(notFoundResponse)
      // then try with v prefix
      .mockResolvedValueOnce(okResponse)

    globalThis.fetch = fetchMock as any

    const { result } = renderHook(() => useChangelog("1.0.0"))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.error).toBeNull()
      expect(result.current.releases).toHaveLength(1)
      expect(result.current.releases[0]).toEqual(release)
    })

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "https://api.github.com/repos/robinebers/openusage/releases/tags/v1.0.0",
    )
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "https://api.github.com/repos/robinebers/openusage/releases/tags/1.0.0",
    )
  })

  it("returns empty releases when tag does not exist for any variant", async () => {
    const notFoundResponse = {
      ok: false,
      status: 404,
      json: async () => ({}),
    } as any

    const fetchMock = vi.fn().mockResolvedValue(notFoundResponse)
    globalThis.fetch = fetchMock as any

    const { result } = renderHook(() => useChangelog("9.9.9"))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.error).toBeNull()
      expect(result.current.releases).toHaveLength(0)
    })

    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it("sets error when fetch fails with non-404", async () => {
    const badResponse = {
      ok: false,
      status: 500,
      json: async () => ({}),
    } as any

    const fetchMock = vi.fn().mockResolvedValue(badResponse)
    globalThis.fetch = fetchMock as any

    const { result } = renderHook(() => useChangelog("1.0.0"))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.releases).toHaveLength(0)
      expect(result.current.error).toBe("Failed to fetch releases")
    })
  })
})

