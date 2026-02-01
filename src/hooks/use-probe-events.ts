import { useCallback, useEffect, useRef } from "react"
import { listen, type UnlistenFn } from "@tauri-apps/api/event"
import { invoke } from "@tauri-apps/api/core"
import type { PluginOutput } from "@/lib/plugin-types"

type ProbeResult = {
  batchId: string
  output: PluginOutput
}

type ProbeBatchComplete = {
  batchId: string
}

type ProbeBatchStarted = {
  batchId: string
  pluginIds: string[]
}

type UseProbeEventsOptions = {
  onResult: (output: PluginOutput) => void
  onBatchComplete: () => void
}

export function useProbeEvents({ onResult, onBatchComplete }: UseProbeEventsOptions) {
  const activeBatchIds = useRef<Set<string>>(new Set())
  const unlisteners = useRef<UnlistenFn[]>([])

  useEffect(() => {
    const setup = async () => {
      const resultUnlisten = await listen<ProbeResult>("probe:result", (event) => {
        if (activeBatchIds.current.has(event.payload.batchId)) {
          onResult(event.payload.output)
        }
      })

      const completeUnlisten = await listen<ProbeBatchComplete>(
        "probe:batch-complete",
        (event) => {
          if (activeBatchIds.current.delete(event.payload.batchId)) {
            onBatchComplete()
          }
        }
      )

      unlisteners.current.push(resultUnlisten, completeUnlisten)
    }

    setup()

    return () => {
      unlisteners.current.forEach((unlisten) => unlisten())
      unlisteners.current = []
    }
  }, [onBatchComplete, onResult])

  const startBatch = useCallback(async (pluginIds?: string[]) => {
    const batchId =
      typeof crypto !== "undefined" && "randomUUID" in crypto
        ? crypto.randomUUID()
        : `batch-${Date.now()}-${Math.random().toString(16).slice(2)}`

    activeBatchIds.current.add(batchId)
    const args = pluginIds ? { batchId, pluginIds } : { batchId }
    try {
      const result = await invoke<ProbeBatchStarted>("start_probe_batch", args)
      return result.pluginIds
    } catch (error) {
      activeBatchIds.current.delete(batchId)
      throw error
    }
  }, [])

  return { startBatch }
}
