import { useState, useEffect, useCallback, useRef } from "react"
import { isTauri } from "@tauri-apps/api/core"
import { check, type Update } from "@tauri-apps/plugin-updater"
import { relaunch } from "@tauri-apps/plugin-process"

export type UpdateStatus =
  | { status: "idle" }
  | { status: "available"; version: string }
  | { status: "downloading"; progress: number } // 0-100, or -1 if indeterminate
  | { status: "installing" }
  | { status: "ready" }
  | { status: "error"; message: string }

interface UseAppUpdateReturn {
  updateStatus: UpdateStatus
  triggerDownload: () => void
  triggerInstall: () => void
}

export function useAppUpdate(): UseAppUpdateReturn {
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus>({ status: "idle" })
  const statusRef = useRef<UpdateStatus>({ status: "idle" })
  const updateRef = useRef<Update | null>(null)
  const mountedRef = useRef(true)
  const inFlightRef = useRef({ downloading: false, installing: false })

  const setStatus = useCallback((next: UpdateStatus) => {
    statusRef.current = next
    if (!mountedRef.current) return
    setUpdateStatus(next)
  }, [])

  useEffect(() => {
    let cancelled = false
    mountedRef.current = true

    const checkForUpdate = async () => {
      if (!isTauri()) return
      try {
        const update = await check()
        if (cancelled) return
        if (update) {
          updateRef.current = update
          setStatus({ status: "available", version: update.version })
        }
      } catch (err) {
        if (cancelled) return
        console.error("Update check failed:", err)
      }
    }

    void checkForUpdate()

    return () => {
      cancelled = true
      mountedRef.current = false
    }
  }, [setStatus])

  const triggerDownload = useCallback(async () => {
    const update = updateRef.current
    if (!update) return
    if (statusRef.current.status !== "available") return
    if (inFlightRef.current.downloading || inFlightRef.current.installing) return

    inFlightRef.current.downloading = true
    setStatus({ status: "downloading", progress: -1 })

    let totalBytes: number | null = null
    let downloadedBytes = 0

    try {
      await update.download((event) => {
        if (!mountedRef.current) return
        if (event.event === "Started") {
          totalBytes = event.data.contentLength ?? null
          downloadedBytes = 0
          setStatus({
            status: "downloading",
            progress: totalBytes ? 0 : -1,
          })
        } else if (event.event === "Progress") {
          downloadedBytes += event.data.chunkLength
          if (totalBytes && totalBytes > 0) {
            const pct = Math.min(100, Math.round((downloadedBytes / totalBytes) * 100))
            setStatus({ status: "downloading", progress: pct })
          }
        } else if (event.event === "Finished") {
          setStatus({ status: "ready" })
        }
      })
      setStatus({ status: "ready" })
    } catch (err) {
      console.error("Update download failed:", err)
      setStatus({ status: "error", message: "Download failed" })
    } finally {
      inFlightRef.current.downloading = false
    }
  }, [setStatus])

  const triggerInstall = useCallback(async () => {
    const update = updateRef.current
    if (!update) return
    if (statusRef.current.status !== "ready") return
    if (inFlightRef.current.installing || inFlightRef.current.downloading) return

    try {
      inFlightRef.current.installing = true
      setStatus({ status: "installing" })
      await update.install()
      await relaunch()
      setStatus({ status: "idle" })
    } catch (err) {
      console.error("Update install failed:", err)
      setStatus({ status: "error", message: "Install failed" })
    } finally {
      inFlightRef.current.installing = false
    }
  }, [setStatus])

  return { updateStatus, triggerDownload, triggerInstall }
}
