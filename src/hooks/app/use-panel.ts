import { useEffect, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { getCurrentWindow, PhysicalSize, currentMonitor } from "@tauri-apps/api/window"
import type { ActiveView } from "@/components/side-nav"

const PANEL_WIDTH = 400
const PANEL_HEIGHT = 500
const MAX_HEIGHT_FALLBACK_PX = 600
const MAX_HEIGHT_FRACTION_OF_MONITOR = 0.8

type UsePanelArgs = {
  activeView: ActiveView
  setActiveView: (view: ActiveView) => void
  showAbout: boolean
  setShowAbout: (value: boolean) => void
}

export function usePanel({
  activeView,
  setActiveView,
  showAbout,
  setShowAbout,
}: UsePanelArgs) {
  const containerRef = useRef<HTMLDivElement>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const [canScrollDown, setCanScrollDown] = useState(false)
  const [panelHeightPx, setPanelHeightPx] = useState<number>(PANEL_HEIGHT)

  useEffect(() => {
    if (!isTauri()) return
    invoke("init_panel").catch(console.error)
  }, [])

  useEffect(() => {
    if (!isTauri()) return
    if (showAbout) return

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        invoke("hide_panel")
      }
    }

    document.addEventListener("keydown", handleKeyDown)
    return () => document.removeEventListener("keydown", handleKeyDown)
  }, [showAbout])

  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false
    const unlisteners: (() => void)[] = []

    async function setup() {
      const u1 = await listen<string>("tray:navigate", (event) => {
        setActiveView(event.payload as ActiveView)
      })
      if (cancelled) {
        u1()
        return
      }
      unlisteners.push(u1)

      const u2 = await listen("tray:show-about", () => {
        setShowAbout(true)
      })
      if (cancelled) {
        u2()
        return
      }
      unlisteners.push(u2)
    }

    void setup()

    return () => {
      cancelled = true
      for (const fn of unlisteners) {
        if (typeof fn === "function") {
          fn()
        }
      }
    }
  }, [setActiveView, setShowAbout])

  useEffect(() => {
    if (!isTauri()) return
    let cancelled = false

    const syncWindowSize = async () => {
      const factor = window.devicePixelRatio
      const width = Math.ceil(PANEL_WIDTH * factor)
      let maxHeightLogical: number | null = null

      try {
        const monitor = await currentMonitor()
        if (monitor) {
          const maxHeightPhysical = Math.floor(monitor.size.height * MAX_HEIGHT_FRACTION_OF_MONITOR)
          maxHeightLogical = Math.floor(maxHeightPhysical / factor)
        }
      } catch {
        // fall through to fallback
      }

      if (maxHeightLogical === null) {
        const screenAvailHeight = Number(window.screen?.availHeight) || MAX_HEIGHT_FALLBACK_PX
        maxHeightLogical = Math.floor(screenAvailHeight * MAX_HEIGHT_FRACTION_OF_MONITOR)
      }

      const heightLogical = Math.max(1, Math.min(PANEL_HEIGHT, maxHeightLogical))

      if (!cancelled) {
        setPanelHeightPx(heightLogical)
      }

      const height = Math.ceil(heightLogical * factor)

      try {
        const currentWindow = getCurrentWindow()
        await currentWindow.setSize(new PhysicalSize(width, height))
      } catch (e) {
        console.error("Failed to resize window:", e)
      }
    }

    void syncWindowSize()

    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return

    const check = () => {
      setCanScrollDown(el.scrollHeight - el.scrollTop - el.clientHeight > 1)
    }

    check()
    el.addEventListener("scroll", check, { passive: true })

    const ro = new ResizeObserver(check)
    ro.observe(el)

    const mo = new MutationObserver(check)
    mo.observe(el, { childList: true, subtree: true })

    return () => {
      el.removeEventListener("scroll", check)
      ro.disconnect()
      mo.disconnect()
    }
  }, [activeView])

  return {
    containerRef,
    scrollRef,
    canScrollDown,
    panelHeightPx,
  }
}
