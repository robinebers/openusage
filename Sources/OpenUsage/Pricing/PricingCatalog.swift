import Foundation

/// One pricing source (LiteLLM or models.dev) as a flat model-key -> rates table with ccusage's
/// lookup semantics: exact key first, then a boundary-aware fuzzy match that tolerates provider
/// prefixes (`xai/grok-4.3`), separator variants (`.` / `@` vs `-`), and date suffixes
/// (`claude-sonnet-4` -> `claude-sonnet-4-20250514`) without conflating numeric versions
/// (`claude-sonnet-4` never matches `claude-sonnet-4-5`).
struct PricingCatalog: Sendable, Equatable {
    var entries: [String: ModelRates]
    /// When the source published its data (informational, for logs).
    var retrievedAt: String?

    init(entries: [String: ModelRates] = [:], retrievedAt: String? = nil) {
        self.entries = entries
        self.retrievedAt = retrievedAt
    }

    func findExact(_ model: String) -> (key: String, rates: ModelRates)? {
        entries[model].map { (model, $0) }
    }

    /// Fuzzy lookup over every entry; prefers the longest matching key (then the lexicographically
    /// smallest for determinism). Only called after exact lookups miss.
    func findFuzzy(_ model: String) -> (key: String, rates: ModelRates)? {
        let normalizedModel = Self.normalizedKey(model)
        var best: (key: String, rates: ModelRates)?
        for (key, rates) in entries {
            guard Self.keyMatches(candidate: key, model: model, normalizedModel: normalizedModel) else { continue }
            if let current = best {
                if key.count > current.key.count || (key.count == current.key.count && key < current.key) {
                    best = (key, rates)
                }
            } else {
                best = (key, rates)
            }
        }
        return best
    }

    /// Merge another catalog on top of this one; `other`'s entries win per key.
    func merging(_ other: PricingCatalog) -> PricingCatalog {
        var merged = entries
        merged.merge(other.entries) { _, new in new }
        return PricingCatalog(entries: merged, retrievedAt: other.retrievedAt ?? retrievedAt)
    }
}

// MARK: - Fuzzy matching (port of ccusage pricing.rs)

extension PricingCatalog {
    /// Normalizes separator variants: `.` and `@` become `-` (`grok-4.3` -> `grok-4-3`).
    static func normalizedKey(_ value: String) -> String {
        guard value.contains(".") || value.contains("@") else { return value }
        return value.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "@", with: "-")
    }

    /// A candidate key matches when either string contains the other at word boundaries, on the raw
    /// or separator-normalized forms.
    static func keyMatches(candidate: String, model: String, normalizedModel: String) -> Bool {
        if containsKey(model, key: candidate) || containsKey(candidate, key: model) {
            return true
        }
        let normalizedCandidate = normalizedKey(candidate)
        return containsKey(normalizedModel, key: normalizedCandidate)
            || containsKey(normalizedCandidate, key: normalizedModel)
    }

    /// Finds `key` inside `value` only where the surrounding characters are non-alphanumeric
    /// boundaries, and the suffix does not continue a numeric version.
    static func containsKey(_ value: String, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let valueBytes = Array(value.utf8)
        let keyBytes = Array(key.utf8)
        guard keyBytes.count <= valueBytes.count else { return false }
        for start in 0...(valueBytes.count - keyBytes.count) {
            guard valueBytes[start..<(start + keyBytes.count)].elementsEqual(keyBytes) else { continue }
            let beforeOK = start == 0 || !valueBytes[start - 1].isASCIIAlphanumeric
            guard beforeOK else { continue }
            let suffix = Array(valueBytes[(start + keyBytes.count)...])
            if suffixAllowsMatch(key: keyBytes, suffix: suffix) {
                return true
            }
        }
        return false
    }

    private static func suffixAllowsMatch(key: [UInt8], suffix: [UInt8]) -> Bool {
        guard let separator = suffix.first else { return true }
        if separator.isASCIIAlphanumeric { return false }
        return !suffixStartsWithNumericModelVersion(key: key, suffix: suffix)
    }

    /// Rejects matches where the suffix looks like a version continuation of a numeric key
    /// (`claude-sonnet-4` + `-5-...`), while allowing 8-digit date suffixes (`-20250514`).
    private static func suffixStartsWithNumericModelVersion(key: [UInt8], suffix: [UInt8]) -> Bool {
        let dateSuffixDigits = 8
        guard let last = key.last, last.isASCIIDigit else { return false }
        guard let separator = suffix.first, separator == UInt8(ascii: "-") || separator == UInt8(ascii: ".") else {
            return false
        }
        let rest = suffix.dropFirst()
        let digitCount = rest.prefix(while: \.isASCIIDigit).count
        guard digitCount > 0 else { return false }
        let afterDigits = rest.dropFirst(digitCount).first
        let isDateSuffix = digitCount == dateSuffixDigits && (afterDigits.map { !$0.isASCIIAlphanumeric } ?? true)
        return !isDateSuffix
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    var isASCIIAlphanumeric: Bool {
        isASCIIDigit
            || (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
    }
}
