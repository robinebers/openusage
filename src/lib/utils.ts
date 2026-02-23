import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0
  if (value < 0) return 0
  if (value > 1) return 1
  return value
}

export function formatFixedPrecisionNumber(value: number): string {
  if (!Number.isFinite(value)) return "0"
  const fractionDigits = Number.isInteger(value) ? 0 : 2
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
  }).format(value)
}

export function formatCountNumber(value: number): string {
  if (!Number.isFinite(value)) return "0"
  const maximumFractionDigits = Number.isInteger(value) ? 0 : 2
  return new Intl.NumberFormat("en-US", { maximumFractionDigits }).format(value)
}
