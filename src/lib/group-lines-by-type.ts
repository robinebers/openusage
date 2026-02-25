export type LineGroup<T extends { type: string }> =
  | { kind: "text"; lines: T[] }
  | { kind: "other"; lines: T[] }

export function groupLinesByType<T extends { type: string }>(lines: T[]): LineGroup<T>[] {
  const groups: LineGroup<T>[] = []
  for (const line of lines) {
    const kind = line.type === "text" ? "text" : "other"
    const last = groups[groups.length - 1]
    if (last && last.kind === kind) {
      last.lines.push(line)
    } else {
      groups.push({ kind, lines: [line] })
    }
  }
  return groups
}
