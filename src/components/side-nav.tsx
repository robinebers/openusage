import { CircleHelp, Settings } from "lucide-react"
import { openUrl } from "@tauri-apps/plugin-opener"
import { invoke } from "@tauri-apps/api/core"

function GaugeIcon({ className }: { className?: string }) {
  return (
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" className={className}>
      <path d="M12 2C17.5228 2 22 6.47715 22 12C22 17.5228 17.5228 22 12 22C6.47715 22 2 17.5228 2 12C2 6.47715 6.47715 2 12 2ZM12 4C7.58172 4 4 7.58172 4 12C4 16.4183 7.58172 20 12 20C16.4183 20 20 16.4183 20 12C20 7.58172 16.4183 4 12 4ZM15.8329 7.33748C16.0697 7.17128 16.3916 7.19926 16.5962 7.40381C16.8002 7.60784 16.8267 7.92955 16.6587 8.16418C14.479 11.2095 13.2796 12.8417 13.0607 13.0607C12.4749 13.6464 11.5251 13.6464 10.9393 13.0607C10.3536 12.4749 10.3536 11.5251 10.9393 10.9393C11.3126 10.5661 12.9438 9.36549 15.8329 7.33748ZM17.5 11C18.0523 11 18.5 11.4477 18.5 12C18.5 12.5523 18.0523 13 17.5 13C16.9477 13 16.5 12.5523 16.5 12C16.5 11.4477 16.9477 11 17.5 11ZM6.5 11C7.05228 11 7.5 11.4477 7.5 12C7.5 12.5523 7.05228 13 6.5 13C5.94772 13 5.5 12.5523 5.5 12C5.5 11.4477 5.94772 11 6.5 11ZM8.81802 7.40381C9.20854 7.79433 9.20854 8.4275 8.81802 8.81802C8.4275 9.20854 7.79433 9.20854 7.40381 8.81802C7.01328 8.4275 7.01328 7.79433 7.40381 7.40381C7.79433 7.01328 8.4275 7.01328 8.81802 7.40381ZM12 5.5C12.5523 5.5 13 5.94772 13 6.5C13 7.05228 12.5523 7.5 12 7.5C11.4477 7.5 11 7.05228 11 6.5C11 5.94772 11.4477 5.5 12 5.5Z" />
    </svg>
  )
}
import { cn } from "@/lib/utils"
import { getRelativeLuminance } from "@/lib/color"
import { useDarkMode } from "@/hooks/use-dark-mode"

type ActiveView = "home" | "settings" | string

interface NavPlugin {
  id: string
  name: string
  iconUrl: string
  brandColor?: string
}

interface SideNavProps {
  activeView: ActiveView
  onViewChange: (view: ActiveView) => void
  plugins: NavPlugin[]
}

interface NavButtonProps {
  isActive: boolean
  onClick: () => void
  children: React.ReactNode
  "aria-label"?: string
}

function NavButton({ isActive, onClick, children, "aria-label": ariaLabel }: NavButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={ariaLabel}
      className={cn(
        "relative flex items-center justify-center w-full p-2.5 transition-colors",
        "hover:bg-accent",
        isActive
          ? "text-foreground before:absolute before:left-0 before:top-1.5 before:bottom-1.5 before:w-0.5 before:bg-primary dark:before:bg-page-accent before:rounded-full"
          : "text-muted-foreground"
      )}
    >
      {children}
    </button>
  )
}

function getIconColor(brandColor: string | undefined, isDark: boolean): string {
  if (!brandColor) return "currentColor"
  const luminance = getRelativeLuminance(brandColor)
  if (isDark && luminance < 0.15) return "#ffffff"
  if (!isDark && luminance > 0.85) return "currentColor"
  return brandColor
}

export function SideNav({ activeView, onViewChange, plugins }: SideNavProps) {
  const isDark = useDarkMode()

  return (
    <nav className="flex flex-col w-12 border-r bg-muted/50 dark:bg-card py-3">
      {/* Home */}
      <NavButton
        isActive={activeView === "home"}
        onClick={() => onViewChange("home")}
        aria-label="Home"
      >
        <GaugeIcon className="size-6 dark:text-page-accent" />
      </NavButton>

      {/* Plugin icons */}
      {plugins.map((plugin) => (
        <NavButton
          key={plugin.id}
          isActive={activeView === plugin.id}
          onClick={() => onViewChange(plugin.id)}
          aria-label={plugin.name}
        >
          <span
            role="img"
            aria-label={plugin.name}
            className="size-6 inline-block"
            style={{
              backgroundColor: getIconColor(plugin.brandColor, isDark),
              WebkitMaskImage: `url(${plugin.iconUrl})`,
              WebkitMaskSize: "contain",
              WebkitMaskRepeat: "no-repeat",
              WebkitMaskPosition: "center",
              maskImage: `url(${plugin.iconUrl})`,
              maskSize: "contain",
              maskRepeat: "no-repeat",
              maskPosition: "center",
            }}
          />
        </NavButton>
      ))}

      {/* Spacer */}
      <div className="flex-1" />

      {/* Help */}
      <NavButton
        isActive={false}
        onClick={() => {
          openUrl("https://github.com/robinebers/openusage/issues").catch(console.error)
          invoke("hide_panel").catch(console.error)
        }}
        aria-label="Help"
      >
        <CircleHelp className="size-6" />
      </NavButton>

      {/* Settings */}
      <NavButton
        isActive={activeView === "settings"}
        onClick={() => onViewChange("settings")}
        aria-label="Settings"
      >
        <Settings className="size-6" />
      </NavButton>
    </nav>
  )
}

export type { ActiveView, NavPlugin }
