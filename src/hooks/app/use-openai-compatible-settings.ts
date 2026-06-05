import { useCallback, useEffect, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { writeText } from "@tauri-apps/plugin-clipboard-manager"
import {
  DEFAULT_OPENAI_COMPATIBLE_SETTINGS,
  loadOpenAICompatibleSettings,
  saveOpenAICompatibleSettings,
  type OpenAICompatibleSettings,
} from "@/lib/settings"

export type OpenAIProxySecretStatus = {
  hasUpstreamKey: boolean
  hasLocalToken: boolean
}

const EMPTY_SECRET_STATUS: OpenAIProxySecretStatus = {
  hasUpstreamKey: false,
  hasLocalToken: false,
}

export function useOpenAICompatibleSettings() {
  const [settings, setSettings] = useState<OpenAICompatibleSettings>(
    DEFAULT_OPENAI_COMPATIBLE_SETTINGS
  )
  const [secretStatus, setSecretStatus] = useState<OpenAIProxySecretStatus>(EMPTY_SECRET_STATUS)
  const [localToken, setLocalToken] = useState<string | null>(null)

  useEffect(() => {
    let isMounted = true

    async function load() {
      try {
        const loaded = await loadOpenAICompatibleSettings()
        if (isMounted) setSettings(loaded)
      } catch (error) {
        console.error("Failed to load OpenAI-compatible settings:", error)
      }

      if (!isTauri()) return
      try {
        const status = await invoke<OpenAIProxySecretStatus>("get_openai_proxy_secret_status")
        if (isMounted) setSecretStatus(status)
      } catch (error) {
        console.error("Failed to load OpenAI-compatible secret status:", error)
      }
    }

    void load()
    return () => {
      isMounted = false
    }
  }, [])

  const handleSettingsChange = useCallback((next: OpenAICompatibleSettings) => {
    setSettings(next)
    void saveOpenAICompatibleSettings(next).catch((error) => {
      console.error("Failed to save OpenAI-compatible settings:", error)
    })
  }, [])

  const handleUpstreamKeySave = useCallback(async (value: string) => {
    if (!isTauri()) return
    const status = await invoke<OpenAIProxySecretStatus>("save_openai_proxy_upstream_key", { value })
    setSecretStatus(status)
  }, [])

  const handleLocalTokenReveal = useCallback(async () => {
    if (!isTauri()) return
    const token = await invoke<string>("get_openai_proxy_local_token")
    setLocalToken(token)
    setSecretStatus((prev) => ({ ...prev, hasLocalToken: true }))
  }, [])

  const handleLocalTokenRegenerate = useCallback(async () => {
    if (!isTauri()) return
    const token = await invoke<string>("regenerate_openai_proxy_local_token")
    setLocalToken(token)
    setSecretStatus((prev) => ({ ...prev, hasLocalToken: true }))
  }, [])

  const handleLocalTokenCopy = useCallback(async () => {
    if (!localToken) return
    await writeText(localToken)
  }, [localToken])

  return {
    openAICompatibleSettings: settings,
    openAIProxySecretStatus: secretStatus,
    openAIProxyLocalToken: localToken,
    handleOpenAICompatibleSettingsChange: handleSettingsChange,
    handleOpenAIProxyUpstreamKeySave: handleUpstreamKeySave,
    handleOpenAIProxyLocalTokenReveal: handleLocalTokenReveal,
    handleOpenAIProxyLocalTokenCopy: handleLocalTokenCopy,
    handleOpenAIProxyLocalTokenRegenerate: handleLocalTokenRegenerate,
  }
}
