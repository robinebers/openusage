import { Ban, CircleHelp, Clock3 } from "lucide-react"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import type { WindowsProviderAvailabilityNote } from "@/lib/windows-provider-support"

const AVAILABILITY_ICON = {
  "not-detected": CircleHelp,
  planned: Clock3,
  blocked: Ban,
} as const

export function ProviderAvailabilityNote({ note }: { note: WindowsProviderAvailabilityNote }) {
  const Icon = AVAILABILITY_ICON[note.kind]

  return (
    <Alert className="mb-3 border-border/70 bg-muted/30 text-foreground">
      <Icon className="h-4 w-4" />
      <AlertTitle>{note.title}</AlertTitle>
      <AlertDescription>{note.message}</AlertDescription>
    </Alert>
  )
}
