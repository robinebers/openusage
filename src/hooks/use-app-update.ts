import { useState, useEffect, useCallback, useRef } from "react"
import { check, type Update } from "@tauri-apps/plugin-updater"
import { relaunch } from "@tauri-apps/plugin-process"

export type UpdateStatus =
  | { status: "idle" }
  | { status: "available"; version: string }
  | { status: "downloading"; progress: number } // 0-100, or -1 if indeterminate
  | { status: "ready" }
  | { status: "error"; message: string }

interface UseAppUpdateReturn {
  updateStatus: UpdateStatus
  triggerDownload: () => void
  triggerInstall: () => void
}

export function useAppUpdate(): UseAppUpdateReturn {
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus>({ status: "idle" })
  const updateRef = useRef<Update | null>(null)

  useEffect(() => {
    let cancelled = false

    const checkForUpdate = async () => {
      try {
        const update = await check()
        if (cancelled) return
        if (update) {
          updateRef.current = update
          setUpdateStatus({ status: "available", version: update.version })
        }
      } catch (err) {
        if (cancelled) return
        console.error("Update check failed:", err)
      }
    }

    void checkForUpdate()

    return () => {
      cancelled = true
    }
  }, [])

  const triggerDownload = useCallback(async () => {
    const update = updateRef.current
    if (!update || updateStatus.status !== "available") return

    setUpdateStatus({ status: "downloading", progress: -1 })

    let totalBytes: number | null = null
    let downloadedBytes = 0

    try {
      await update.download((event) => {
        if (event.event === "Started") {
          totalBytes = event.data.contentLength ?? null
          downloadedBytes = 0
          setUpdateStatus({
            status: "downloading",
            progress: totalBytes ? 0 : -1,
          })
        } else if (event.event === "Progress") {
          downloadedBytes += event.data.chunkLength
          if (totalBytes && totalBytes > 0) {
            const pct = Math.min(100, Math.round((downloadedBytes / totalBytes) * 100))
            setUpdateStatus({ status: "downloading", progress: pct })
          }
        } else if (event.event === "Finished") {
          setUpdateStatus({ status: "ready" })
        }
      })
      setUpdateStatus({ status: "ready" })
    } catch (err) {
      console.error("Update download failed:", err)
      setUpdateStatus({ status: "error", message: "Download failed" })
    }
  }, [updateStatus])

  const triggerInstall = useCallback(async () => {
    const update = updateRef.current
    if (!update || updateStatus.status !== "ready") return

    try {
      await update.install()
      await relaunch()
    } catch (err) {
      console.error("Update install failed:", err)
      setUpdateStatus({ status: "error", message: "Install failed" })
    }
  }, [updateStatus])

  return { updateStatus, triggerDownload, triggerInstall }
}
