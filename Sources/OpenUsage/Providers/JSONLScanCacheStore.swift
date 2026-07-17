import Darwin
import Foundation

/// Disk policy for one JSONL parser. `namespace` identifies the provider/parser; the scanner adds a
/// stable provider/home identity below it. Bump `schemaVersion` whenever the persisted item meaning
/// changes, including changes to nested values such as `TokenBreakdown`.
struct JSONLScanCachePersistence: Sendable {
    var namespace: String
    var schemaVersion: Int
    var directory: URL
    var writeDebounce: Duration

    init(
        namespace: String,
        schemaVersion: Int,
        directory: URL = JSONLScanCachePaths.defaultDirectory,
        writeDebounce: Duration = .seconds(2)
    ) {
        precondition(!namespace.isEmpty)
        precondition(namespace.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        precondition(schemaVersion > 0)
        self.namespace = namespace
        self.schemaVersion = schemaVersion
        self.directory = directory
        self.writeDebounce = writeDebounce
    }
}

struct JSONLScanCacheFileMetadata: Codable, Sendable, Equatable {
    var size: Int
    var mtime: Date
    var recordFileName: String
}

struct JSONLScanCacheManifest: Codable, Sendable {
    var formatVersion: Int
    var schemaVersion: Int
    var identity: String
    /// Diagnostic/retention timestamp for the last successful lock-scoped manifest merge.
    var generatedAt: Date
    var files: [String: JSONLScanCacheFileMetadata]
}

struct JSONLScanCacheUpsert: Sendable {
    var metadata: JSONLScanCacheFileMetadata
    var recordData: Data
}

struct JSONLScanCacheWriteBatch: Sendable {
    var persistence: JSONLScanCachePersistence
    var identity: String
    /// Only new or changed source paths are present. The writer verifies each path's current stat before
    /// publishing it, so a slow process cannot replace a newer parse of the same source file.
    var upserts: [String: JSONLScanCacheUpsert]
    /// A removal applies only while the on-disk metadata still equals the value this scanner observed.
    /// Paths added or changed by another app/CLI process are therefore preserved.
    var removals: [String: JSONLScanCacheFileMetadata]
}

struct JSONLScanCacheCommitResult: Sendable {
    var manifest: JSONLScanCacheManifest
    var acceptedUpsertPaths: Set<String>
}

struct JSONLScanCacheRecord<Item: Codable & Sendable>: Codable, Sendable {
    var path: String
    var size: Int
    var mtime: Date
    var items: [Item]
}

struct JSONLScanCachedFile<Item: Codable & Sendable>: Sendable {
    var size: Int
    var mtime: Date
    var items: [Item]
}

struct JSONLScanCacheReadSnapshot<Item: Codable & Sendable>: Sendable {
    var manifest: JSONLScanCacheManifest
    var files: [String: JSONLScanCachedFile<Item>]
    var invalidRecords: [String: JSONLScanCacheFileMetadata]
}

enum JSONLScanCachePaths {
    static let formatVersion = 1
    static let staleIdentityRetention: TimeInterval = 35 * 86_400

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/log-scan-cache", isDirectory: true)
    }

    static func identityDirectory(
        persistence: JSONLScanCachePersistence,
        identity: String
    ) -> URL {
        persistence.directory.appendingPathComponent(
            "\(persistence.namespace)-\(stableFingerprint(identity))",
            isDirectory: true
        )
    }

    static func manifestURL(persistence: JSONLScanCachePersistence, identity: String) -> URL {
        identityDirectory(persistence: persistence, identity: identity)
            .appendingPathComponent("manifest.plist")
    }

    static func recordsDirectory(persistence: JSONLScanCachePersistence, identity: String) -> URL {
        identityDirectory(persistence: persistence, identity: identity)
            .appendingPathComponent("files", isDirectory: true)
    }

    static func recordFileName(path: String) -> String {
        "\(stableFingerprint(path)).plist"
    }

    static func recordURL(
        persistence: JSONLScanCachePersistence,
        identity: String,
        fileName: String
    ) -> URL {
        recordsDirectory(persistence: persistence, identity: identity)
            .appendingPathComponent(fileName)
    }

    static func lockURL(persistence: JSONLScanCachePersistence, identity: String) -> URL {
        let directoryName = identityDirectory(persistence: persistence, identity: identity).lastPathComponent
        return persistence.directory.appendingPathComponent(".\(directoryName).lock")
    }

    /// Swift's `Hasher` is randomized per process; FNV-1a gives stable compact names across launches.
    /// Manifests/records also carry and validate the unhashed identity/path, so a theoretical collision
    /// causes a safe reparse instead of serving another source's items.
    static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

/// Serializes manifest publication within the process and uses `flock` to order app/CLI writers. Each
/// batch carries path-level mutations, which are merged with the current manifest while locked so
/// overlapping processes preserve one another's work. Records land before the manifest, so a crash can
/// leave an orphan record but never publish metadata for a half-written one.
actor JSONLScanCacheWriter {
    static let shared = JSONLScanCacheWriter()

    func commit(_ batch: JSONLScanCacheWriteBatch) throws -> JSONLScanCacheCommitResult {
        let persistence = batch.persistence
        let identity = batch.identity
        let manifestURL = JSONLScanCachePaths.manifestURL(
            persistence: persistence,
            identity: identity
        )

        return try Self.withExclusiveLock(
            at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
        ) {
            let current = Self.readManifest(at: manifestURL)
            var mergedFiles: [String: JSONLScanCacheFileMetadata]
            if current?.formatVersion == JSONLScanCachePaths.formatVersion,
               current?.schemaVersion == persistence.schemaVersion,
               current?.identity == identity
            {
                mergedFiles = current?.files ?? [:]
            } else {
                mergedFiles = [:]
            }

            for (path, expectedMetadata) in batch.removals
                where mergedFiles[path] == expectedMetadata
            {
                mergedFiles[path] = nil
            }

            let identityDirectory = JSONLScanCachePaths.identityDirectory(
                persistence: persistence,
                identity: identity
            )
            let recordsDirectory = JSONLScanCachePaths.recordsDirectory(
                persistence: persistence,
                identity: identity
            )
            var acceptedUpsertPaths: Set<String> = []
            if !batch.upserts.isEmpty {
                try Self.createPrivateDirectory(persistence.directory)
                try Self.createPrivateDirectory(identityDirectory)
                try Self.createPrivateDirectory(recordsDirectory)
                for (path, upsert) in batch.upserts
                    where Self.sourceMatches(path: path, metadata: upsert.metadata)
                {
                    try Self.writePrivate(
                        upsert.recordData,
                        to: recordsDirectory.appendingPathComponent(upsert.metadata.recordFileName)
                    )
                    mergedFiles[path] = upsert.metadata
                    acceptedUpsertPaths.insert(path)
                }
            }

            let manifest = JSONLScanCacheManifest(
                formatVersion: JSONLScanCachePaths.formatVersion,
                schemaVersion: persistence.schemaVersion,
                identity: identity,
                generatedAt: Date(),
                files: mergedFiles
            )
            if mergedFiles.isEmpty {
                if FileManager.default.fileExists(atPath: identityDirectory.path) {
                    try FileManager.default.removeItem(at: identityDirectory)
                }
                return JSONLScanCacheCommitResult(
                    manifest: manifest,
                    acceptedUpsertPaths: acceptedUpsertPaths
                )
            }

            try Self.createPrivateDirectory(persistence.directory)
            try Self.createPrivateDirectory(identityDirectory)
            try Self.createPrivateDirectory(recordsDirectory)
            // Publish metadata last. A reader either sees the complete old generation or complete new one.
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try Self.writePrivate(try encoder.encode(manifest), to: manifestURL)

            let referenced = Set(mergedFiles.values.map(\.recordFileName))
            let existing = try FileManager.default.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for url in existing where url.pathExtension == "plist" && !referenced.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
            return JSONLScanCacheCommitResult(
                manifest: manifest,
                acceptedUpsertPaths: acceptedUpsertPaths
            )
        }
    }

    /// Reads one identity under a shared cross-process lock and marks it recently used before releasing
    /// that lock. A concurrent stale-cache cleanup must then re-check the touched directory and keep it.
    nonisolated func load<Item: Codable & Sendable>(
        persistence: JSONLScanCachePersistence,
        identity: String,
        itemType: Item.Type
    ) throws -> JSONLScanCacheReadSnapshot<Item>? {
        _ = itemType
        let identityDirectory = JSONLScanCachePaths.identityDirectory(
            persistence: persistence,
            identity: identity
        )
        guard FileManager.default.fileExists(atPath: identityDirectory.path) else { return nil }
        return try Self.withSharedLock(
            at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
        ) {
            let manifestURL = JSONLScanCachePaths.manifestURL(
                persistence: persistence,
                identity: identity
            )
            let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            let manifest = try PropertyListDecoder().decode(
                JSONLScanCacheManifest.self,
                from: manifestData
            )
            var files: [String: JSONLScanCachedFile<Item>] = [:]
            var invalidRecords: [String: JSONLScanCacheFileMetadata] = [:]
            if manifest.formatVersion == JSONLScanCachePaths.formatVersion,
               manifest.schemaVersion == persistence.schemaVersion,
               manifest.identity == identity
            {
                files.reserveCapacity(manifest.files.count)
                let recordDecoder = PropertyListDecoder()
                for (path, metadata) in manifest.files {
                    let url = JSONLScanCachePaths.recordURL(
                        persistence: persistence,
                        identity: identity,
                        fileName: metadata.recordFileName
                    )
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                          let record = try? recordDecoder.decode(
                              JSONLScanCacheRecord<Item>.self,
                              from: data
                          ),
                          record.path == path,
                          record.size == metadata.size,
                          record.mtime == metadata.mtime
                    else {
                        invalidRecords[path] = metadata
                        continue
                    }
                    files[path] = JSONLScanCachedFile(
                        size: record.size,
                        mtime: record.mtime,
                        items: record.items
                    )
                }
            }
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: identityDirectory.path
                )
            } catch {
                AppLog.warn(
                    .cache,
                    "could not mark \(persistence.namespace) log parse cache as used: \(error.localizedDescription)"
                )
            }
            return JSONLScanCacheReadSnapshot(
                manifest: manifest,
                files: files,
                invalidRecords: invalidRecords
            )
        }
    }

    /// Removes identity directories that have not been read or written for longer than the retained scan
    /// window. The tiny lock files contain no usage data and intentionally remain: unlinking a lock
    /// file while another process holds its inode would undermine cross-process exclusion.
    func pruneStaleIdentities(
        persistence: JSONLScanCachePersistence,
        before cutoff: Date
    ) {
        let prefix = "\(persistence.namespace)-"
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: persistence.directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for directory in contents where directory.lastPathComponent.hasPrefix(prefix) {
            guard let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ),
            values.isDirectory == true,
            let modified = values.contentModificationDate,
            modified < cutoff
            else { continue }

            let lockURL = persistence.directory.appendingPathComponent(".\(directory.lastPathComponent).lock")
            do {
                try Self.withExclusiveLock(at: lockURL, nonblocking: true) {
                    guard let lockedValues = try? directory.resourceValues(
                        forKeys: [.isDirectoryKey, .contentModificationDateKey]
                    ),
                    lockedValues.isDirectory == true,
                    let lockedModified = lockedValues.contentModificationDate,
                    lockedModified < cutoff
                    else { return }
                    try FileManager.default.removeItem(at: directory)
                }
            } catch let error as POSIXError where error.code == .EWOULDBLOCK {
                continue
            } catch {
                AppLog.warn(
                    .cache,
                    "could not prune stale \(persistence.namespace) log parse cache: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func readManifest(at url: URL) -> JSONLScanCacheManifest? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? PropertyListDecoder().decode(JSONLScanCacheManifest.self, from: data)
    }

    private static func sourceMatches(
        path: String,
        metadata: JSONLScanCacheFileMetadata
    ) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else {
            return false
        }
        return values.isRegularFile == true
            && values.fileSize == metadata.size
            && values.contentModificationDate == metadata.mtime
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func withExclusiveLock<Result>(
        at url: URL,
        nonblocking: Bool = false,
        _ body: () throws -> Result
    ) throws -> Result {
        try withLock(
            at: url,
            operation: LOCK_EX | (nonblocking ? LOCK_NB : 0),
            body
        )
    }

    private static func withSharedLock<Result>(
        at url: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        try withLock(at: url, operation: LOCK_SH, body)
    }

    private static func withLock<Result>(
        at url: URL,
        operation: Int32,
        _ body: () throws -> Result
    ) throws -> Result {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        guard Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, operation) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return try body()
    }
}
