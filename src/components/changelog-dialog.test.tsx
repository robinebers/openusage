import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi, beforeEach } from "vitest"

const openerState = vi.hoisted(() => ({
  openUrlMock: vi.fn(() => Promise.resolve()),
}))

const changelogState = vi.hoisted(() => ({
  releases: [] as import("@/hooks/use-changelog").Release[],
  loading: false,
  error: null as string | null,
}))

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: openerState.openUrlMock,
}))

vi.mock("@/hooks/use-changelog", () => ({
  useChangelog: () => changelogState,
}))

import { ChangelogDialog } from "@/components/changelog-dialog"

describe("ChangelogDialog", () => {
  beforeEach(() => {
    changelogState.releases = []
    changelogState.loading = false
    changelogState.error = null
    openerState.openUrlMock.mockClear()
  })

  it("renders loading state", () => {
    changelogState.loading = true

    render(
      <ChangelogDialog
        currentVersion="1.0.0"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    expect(screen.getByText("Fetching release info...")).toBeInTheDocument()
  })

  it("renders error state and shows retry button", async () => {
    changelogState.error = "something went wrong"

    render(
      <ChangelogDialog
        currentVersion="1.0.0"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    expect(screen.getByText("Failed to load release notes")).toBeInTheDocument()
    expect(screen.getByText("something went wrong")).toBeInTheDocument()

    const retryButton = screen.getByRole("button", { name: "Try again" })
    expect(retryButton).toBeInTheDocument()
  })

  it("renders current release with markdown content and GitHub link", async () => {
    const body =
      "Intro\n\n" +
      "## Heading\n" +
      "- item\n" +
      "PR #123 by @user in commit abcdef1\n" +
      "See [docs](https://example.com/docs) and https://example.com/plain"

    changelogState.releases = [
      {
        id: 1,
        tag_name: "v1.2.3",
        name: "v1.2.3",
        body,
        published_at: "2024-01-02T00:00:00Z",
        html_url: "https://github.com/robinebers/openusage/releases/tag/v1.2.3",
      },
    ]

    render(
      <ChangelogDialog
        currentVersion="1.2.3"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    expect(screen.getByText("v1.2.3")).toBeInTheDocument()
    expect(screen.getByText("Intro")).toBeInTheDocument()
    expect(screen.getByText("Heading")).toBeInTheDocument()
    expect(screen.getByText("item")).toBeInTheDocument()

    // GitHub button opens the release URL.
    await userEvent.click(screen.getByRole("button", { name: "GitHub" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith(
      "https://github.com/robinebers/openusage/releases/tag/v1.2.3",
    )

    openerState.openUrlMock.mockClear()

    // Markdown link button.
    await userEvent.click(screen.getByRole("button", { name: "docs" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith("https://example.com/docs")

    openerState.openUrlMock.mockClear()

    // PR, user, and commit buttons.
    await userEvent.click(screen.getByRole("button", { name: "#123" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith(
      "https://github.com/robinebers/openusage/pull/123",
    )

    openerState.openUrlMock.mockClear()

    await userEvent.click(screen.getByRole("button", { name: "@user" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith("https://github.com/user")

    openerState.openUrlMock.mockClear()

    await userEvent.click(screen.getByRole("button", { name: "abcdef1" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith(
      "https://github.com/robinebers/openusage/commit/abcdef1",
    )

    openerState.openUrlMock.mockClear()

    await userEvent.click(screen.getByRole("button", { name: "https://example.com/plain" }))
    expect(openerState.openUrlMock).toHaveBeenCalledWith("https://example.com/plain")
  })

  it("handles null body without crashing", () => {
    changelogState.releases = [
      {
        id: 1,
        tag_name: "v1.0.0",
        name: "v1.0.0",
        body: null as any,
        published_at: "2024-01-02T00:00:00Z",
        html_url: "https://github.com/robinebers/openusage/releases/tag/v1.0.0",
      },
    ]

    render(
      <ChangelogDialog
        currentVersion="1.0.0"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    // If it renders the title, we know it didn't crash when rendering the markdown.
    expect(screen.getByText("v1.0.0")).toBeInTheDocument()
  })

  it("handles null published_at gracefully", () => {
    changelogState.releases = [
      {
        id: 1,
        tag_name: "v1.0.1",
        name: "v1.0.1",
        body: "body",
        published_at: null,
        html_url: "https://github.com/robinebers/openusage/releases/tag/v1.0.1",
      },
    ]

    render(
      <ChangelogDialog
        currentVersion="1.0.1"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    expect(screen.getByText("v1.0.1")).toBeInTheDocument()
    expect(screen.getByText("Unpublished release")).toBeInTheDocument()
  })

  it("shows link to full changelog when multiple releases exist", async () => {
    changelogState.releases = [
      {
        id: 1,
        tag_name: "v1.0.0",
        name: "v1.0.0",
        body: "body",
        published_at: "2024-01-02T00:00:00Z",
        html_url: "https://github.com/robinebers/openusage/releases/tag/v1.0.0",
      },
      {
        id: 2,
        tag_name: "v0.9.0",
        name: "v0.9.0",
        body: "older",
        published_at: "2024-01-01T00:00:00Z",
        html_url: "https://github.com/robinebers/openusage/releases/tag/v0.9.0",
      },
    ]

    render(
      <ChangelogDialog
        currentVersion="1.0.0"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    const fullChangelogButton = screen.getByRole("button", { name: "full changelog" })
    await userEvent.click(fullChangelogButton)

    expect(openerState.openUrlMock).toHaveBeenCalledWith(
      "https://github.com/robinebers/openusage/releases",
    )
  })

  it("renders fallback when no current release is found", async () => {
    changelogState.releases = [
      {
        id: 1,
        tag_name: "v0.1.0",
        name: "v0.1.0",
        body: "old",
        published_at: "2023-01-01T00:00:00Z",
        html_url: "https://github.com/robinebers/openusage/releases/tag/v0.1.0",
      },
    ]

    render(
      <ChangelogDialog
        currentVersion="9.9.9"
        onBack={() => {}}
        onClose={() => {}}
      />,
    )

    expect(
      screen.getByText("No specific notes for v9.9.9"),
    ).toBeInTheDocument()

    await userEvent.click(
      screen.getByRole("button", { name: "View all releases on GitHub" }),
    )

    expect(openerState.openUrlMock).toHaveBeenCalledWith(
      "https://github.com/robinebers/openusage/releases",
    )
  })

  it("invokes navigation callbacks and closes on Escape", async () => {
    const onBack = vi.fn()
    const onClose = vi.fn()

    changelogState.releases = [
      {
        id: 1,
        tag_name: "v1.0.0",
        name: "v1.0.0",
        body: "body",
        published_at: "2024-01-02T00:00:00Z",
        html_url: "https://github.com/robinebers/openusage/releases/tag/v1.0.0",
      },
    ]

    render(
      <ChangelogDialog
        currentVersion="1.0.0"
        onBack={onBack}
        onClose={onClose}
      />,
    )

    // Back goes to previous view
    await userEvent.click(screen.getByRole("button", { name: "Back" }))
    expect(onBack).toHaveBeenCalled()

    // Escape should trigger onClose once
    await userEvent.keyboard("{Escape}")
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

