import { useState, useEffect } from "react"

export interface Release {
  id: number
  tag_name: string
  name: string | null
  body: string | null
  published_at: string | null
  html_url: string
}

async function fetchReleaseByTag(tag: string): Promise<Release | null> {
  const url = `https://api.github.com/repos/robinebers/openusage/releases/tags/${encodeURIComponent(
    tag,
  )}`
  const res = await fetch(url)

  if (res.status === 404) {
    return null
  }

  if (!res.ok) {
    throw new Error("Failed to fetch releases")
  }

  const data = (await res.json()) as Release
  return data
}

export function useChangelog(currentVersion: string) {
  const [releases, setReleases] = useState<Release[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let mounted = true

    const fetchForCurrentVersion = async () => {
      setLoading(true)
      setReleases([])
      setError(null)
      try {
        let release: Release | null = null

        if (currentVersion.startsWith("v")) {
          release =
            (await fetchReleaseByTag(currentVersion)) ??
            (await fetchReleaseByTag(currentVersion.slice(1)))
        } else {
          release =
            (await fetchReleaseByTag(`v${currentVersion}`) ??
            (await fetchReleaseByTag(currentVersion)))
        }

        if (mounted) {
          setReleases(release ? [release] : [])
          setError(null)
        }
      } catch (err) {
        if (mounted) {
          const message =
            err instanceof Error ? err.message : "Failed to fetch releases"
          setError(message)
        }
      } finally {
        if (mounted) {
          setLoading(false)
        }
      }
    }

    fetchForCurrentVersion()

    return () => {
      mounted = false
    }
  }, [currentVersion])

  return { releases, loading, error }
}
