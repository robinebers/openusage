import { Skeleton } from "@/components/ui/skeleton"
import type { ManifestLine } from "@/lib/plugin-types"

function SkeletonText({ label }: { label: string }) {
  return (
    <div className="flex justify-between items-center h-[22px]">
      <span className="text-sm text-muted-foreground">{label}</span>
      <Skeleton className="h-5 w-16" />
    </div>
  )
}

function SkeletonBadge({ label }: { label: string }) {
  return (
    <div className="flex justify-between items-center h-[22px]">
      <span className="text-sm text-muted-foreground">{label}</span>
      <Skeleton className="h-5 w-16 rounded-md" />
    </div>
  )
}

function SkeletonProgress({ label }: { label: string }) {
  return (
    <div>
      <div className="text-sm font-medium mb-1.5">{label}</div>
      <Skeleton className="h-3 w-full rounded-full" />
      <div className="flex justify-between items-center mt-1.5">
        <Skeleton className="h-4 w-12" />
        <Skeleton className="h-4 w-24" />
      </div>
    </div>
  )
}

export function SkeletonLine({ line }: { line: ManifestLine }) {
  switch (line.type) {
    case "text":
      return <SkeletonText label={line.label} />
    case "badge":
      return <SkeletonBadge label={line.label} />
    case "progress":
      return <SkeletonProgress label={line.label} />
    default:
      return <SkeletonText label={line.label} />
  }
}

export function SkeletonLines({ lines }: { lines: ManifestLine[] }) {
  return (
    <div className="space-y-4">
      {lines.map((line, index) => (
        <SkeletonLine key={`${line.label}-${index}`} line={line} />
      ))}
    </div>
  )
}
