import { Home, Settings } from "lucide-react"
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
          ? "text-foreground before:absolute before:left-0 before:top-1.5 before:bottom-1.5 before:w-0.5 before:bg-primary before:rounded-full"
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
  if (isDark && luminance < 0.15) return "currentColor"
  if (!isDark && luminance > 0.85) return "currentColor"
  return brandColor
}

export function SideNav({ activeView, onViewChange, plugins }: SideNavProps) {
  const isDark = useDarkMode()

  return (
    <nav className="flex flex-col w-12 border-r bg-muted/30 py-3">
      {/* Home */}
      <NavButton
        isActive={activeView === "home"}
        onClick={() => onViewChange("home")}
        aria-label="Home"
      >
        <Home className="size-6" />
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
