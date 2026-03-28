import { useCallback, useState } from "react"

export type UpdateStatus =
  | { status: "idle" }
  | { status: "checking" }
  | { status: "up-to-date" }
  | { status: "downloading"; progress: number } // 0-100, or -1 if indeterminate
  | { status: "installing" }
  | { status: "ready" }
  | { status: "error"; message: string }

interface UseAppUpdateReturn {
  updateStatus: UpdateStatus
  triggerInstall: () => void
  checkForUpdates: () => void
}

export function useAppUpdate(): UseAppUpdateReturn {
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus>({ status: "idle" })

  const checkForUpdates = useCallback(async () => {
    setUpdateStatus({ status: "idle" })
  }, [])

  const triggerInstall = useCallback(async () => {
    setUpdateStatus({ status: "idle" })
  }, [])

  return { updateStatus, triggerInstall, checkForUpdates }
}
