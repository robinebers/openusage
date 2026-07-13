import Foundation

/// The `Item`-independent half of the incremental scan machinery: file discovery and the scan-window
/// lower bound. A non-generic namespace so providers that only need the window math (Grok) share it
/// without dragging in the generic actor, and so call sites read `JSONLScanning.sinceDate(...)` instead
/// of `IncrementalJSONLScanner<Entry>.sinceDate(...)`.
enum JSONLScanning {
    /// A discovered log file plus the stat fields the parse cache is keyed on.
    struct DiscoveredFile: Sendable {
        var path: String
        var size: Int
        var mtime: Date
    }

    /// Start of the day `daysBack` days before `now` — the lower bound of the scan window.
    static func sinceDate(daysBack: Int, now: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return Calendar.current.startOfDay(for: shifted)
    }

    /// Every `*.jsonl` regular file under `dir` (recursively), path-sorted so a keep-first dedup is
    /// deterministic. Empty when `dir` can't be enumerated.
    static func jsonlFiles(under dir: URL) -> [DiscoveredFile] {
        // `FileManager.enumerator` silently yields nothing when `dir` itself is a symlink.
        // Resolve first so the enumeration sees the real directory.
        let dir = dir.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        var files: [DiscoveredFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files.append(DiscoveredFile(
                path: url.path,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? .distantPast
            ))
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// The incremental, off-main-actor scan machinery shared by the Claude and Codex log scanners: discover
/// `*.jsonl` files, re-parse only those changed since the last scan (a per-file cache keyed by path +
/// size + mtime), and return the parsed items concatenated in file order. Each provider supplies its own
/// file discovery, per-file parser, and post-parse dedup/aggregation; this owns the cache, the parallel
/// parse, the mtime-window skip, and (via `JSONLScanning`) the jsonl enumeration so that scaffolding
/// isn't copied per provider.
///
/// An actor so the parse cache persists across the ~5-minute provider refreshes while staying off the
/// main actor. Held as an instance by each provider scanner; `Item` is the provider's parsed row.
actor IncrementalJSONLScanner<Item: Sendable> {
    private struct CachedFile {
        var size: Int
        var mtime: Date
        var items: [Item]
    }

    private var cache: [String: CachedFile] = [:]
    private let maxConcurrentParses: Int
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        maxConcurrentParses: Int = 8,
        logTag: String = LogTag.refresh.rawValue,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        precondition(maxConcurrentParses > 0)
        self.maxConcurrentParses = maxConcurrentParses
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: logTag, warning: readFailureWarning)
    }

    /// Re-parse the in-window files (reusing the cache on an unchanged path + size + mtime), then return
    /// every file's items concatenated in the input order — callers pass a path-sorted list so a
    /// keep-first dedup stays deterministic. Files whose mtime predates `since` are skipped, so a
    /// years-deep tree stays cheap to rescan; an unreadable file is skipped and not cached, so a
    /// transient read failure doesn't stick.
    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [Item] {
        var nextCache: [String: CachedFile] = [:]
        var toParse: [JSONLScanning.DiscoveredFile] = []
        for file in files {
            guard file.mtime >= since else { continue }
            if let cached = cache[file.path], cached.size == file.size, cached.mtime == file.mtime {
                nextCache[file.path] = cached
            } else {
                toParse.append(file)
            }
        }
        let parseResults = await Self.parseFiles(
            toParse,
            maxConcurrentParses: maxConcurrentParses,
            parse: parse
        )
        let checkedPaths = Set(parseResults.lazy.map(\.file.path))
        let unreadablePaths = Set(parseResults.lazy.filter(\.readFailed).map(\.file.path))
        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: unreadablePaths)
        for result in parseResults {
            let (file, parsed) = (result.file, result.items)
            guard let parsed else { continue }
            nextCache[file.path] = CachedFile(size: file.size, mtime: file.mtime, items: parsed)
        }
        cache = nextCache

        var items: [Item] = []
        for file in files {
            guard let cached = nextCache[file.path] else { continue }
            items.append(contentsOf: cached.items)
        }
        return items
    }

    /// Read + parse a bounded number of changed files in parallel. Results are keyed back to the input
    /// order; a `nil` item list marks an unreadable file.
    private static func parseFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        maxConcurrentParses: Int,
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readFailed: Bool)] {
        await withTaskGroup(
            of: (Int, [Item]?, Bool).self,
            returning: [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readFailed: Bool)].self
        ) { group in
            func addTask(at index: Int) {
                let file = files[index]
                group.addTask {
                    guard FileManager.default.fileExists(atPath: file.path) else {
                        return (index, nil, false)
                    }
                    guard let data = FileManager.default.contents(atPath: file.path) else {
                        return (index, nil, true)
                    }
                    return (index, parse(data), false)
                }
            }

            var nextIndex = 0
            let initialCount = min(maxConcurrentParses, files.count)
            for index in 0..<initialCount {
                addTask(at: index)
                nextIndex += 1
            }

            var results = files.map { (file: $0, items: Optional<[Item]>.none, readFailed: false) }
            for await (index, items, readFailed) in group {
                results[index] = (files[index], items, readFailed)
                if nextIndex < files.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }
    }
}
