import { useEffect, useRef, useState } from "react"
import { invoke, isTauri } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { getCurrentWindow, PhysicalSize, currentMonitor } from "@tauri-apps/api/window"
import type { ActiveView } from "@/components/side-nav"

const PANEL_WIDTH = 400
const PANEL_WINDOW_OVERHEAD_PX = 37
const PANEL_MIN_CONTENT_HEIGHT_PX = 120
// Keep the tray shell stable across short and long provider states; overflow should scroll inside the panel.
const PANEL_PREFERRED_HEIGHT = 560
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
  const [panelHeightPx, setPanelHeightPx] = useState<number | null>(null)
  const panelHeightPxRef = useRef<number | null>(null)
  const lastWindowSizeRef = useRef<{ width: number; height: number } | null>(null)

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
      for (const fn of unlisteners) fn()
    }
  }, [setActiveView, setShowAbout])

  useEffect(() => {
    if (!isTauri()) return
    const container = containerRef.current
    if (!container) return
    const currentWindow = getCurrentWindow()
    let cancelled = false
    const unlisteners: (() => void)[] = []

    const resizeWindow = async () => {
      const factor = window.devicePixelRatio
      const width = Math.ceil(PANEL_WIDTH * factor)

      let maxHeightPhysical: number | null = null
      let maxHeightLogical: number | null = null

      try {
        const monitor = await currentMonitor()
        if (monitor) {
          maxHeightPhysical = Math.floor(monitor.size.height * MAX_HEIGHT_FRACTION_OF_MONITOR)
          maxHeightLogical = Math.floor(maxHeightPhysical / factor)
        }
      } catch {
        // fall through to fallback
      }

      if (maxHeightLogical === null) {
        const screenAvailHeight = Number(window.screen?.availHeight) || MAX_HEIGHT_FALLBACK_PX
        maxHeightLogical = Math.floor(screenAvailHeight * MAX_HEIGHT_FRACTION_OF_MONITOR)
        maxHeightPhysical = Math.floor(maxHeightLogical * factor)
      }

      const minPanelHeightLogical = Math.min(
        maxHeightLogical,
        PANEL_WINDOW_OVERHEAD_PX + PANEL_MIN_CONTENT_HEIGHT_PX
      )

      // Keep the tray panel visually stable; scrolling should happen inside the shell.
      const nextPanelHeightLogical = Math.max(
        minPanelHeightLogical,
        Math.min(PANEL_PREFERRED_HEIGHT, maxHeightLogical)
      )

      if (panelHeightPxRef.current !== nextPanelHeightLogical) {
        panelHeightPxRef.current = nextPanelHeightLogical
        setPanelHeightPx(nextPanelHeightLogical)
      }

      const nextWindowSize = {
        width,
        height: Math.ceil(Math.min(nextPanelHeightLogical * factor, maxHeightPhysical!)),
      }

      if (
        lastWindowSizeRef.current?.width === nextWindowSize.width &&
        lastWindowSizeRef.current?.height === nextWindowSize.height
      ) {
        return
      }

      lastWindowSizeRef.current = nextWindowSize

      try {
        await currentWindow.setSize(new PhysicalSize(nextWindowSize.width, nextWindowSize.height))
      } catch (e) {
        console.error("Failed to resize window:", e)
      }
    }

    void resizeWindow()

    const observer = new ResizeObserver(() => {
      void resizeWindow()
    })
    observer.observe(container)

    async function setupWindowListeners() {
      const unlistenMoved = await currentWindow.onMoved(() => {
        void resizeWindow()
      })
      if (cancelled) {
        unlistenMoved()
        return
      }
      unlisteners.push(unlistenMoved)

      const unlistenScaleChanged = await currentWindow.onScaleChanged(() => {
        void resizeWindow()
      })
      if (cancelled) {
        unlistenScaleChanged()
        return
      }
      unlisteners.push(unlistenScaleChanged)
    }

    void setupWindowListeners()

    return () => {
      cancelled = true
      observer.disconnect()
      for (const fn of unlisteners) fn()
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
