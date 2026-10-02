import Foundation

struct ClaudeSessionOwnershipResolver {
    let readData: @Sendable (URL) throws -> Data
    private var cache: [String: (size: Int, mtime: Date, identity: ClaudeSessionIdentity)] = [:]

    init(readData: @escaping @Sendable (URL) throws -> Data) {
        self.readData = readData
    }

    mutating func files(
        _ files: [JSONLScanning.DiscoveredFile],
        accountID: String?,
        organizationID: String?,
        allowsUnattributedSessions: Bool,
        localProjectRoots: [URL],
        home: URL
    ) -> [JSONLScanning.DiscoveredFile]? {
        let coworkPrefix = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
            .resolvingSymlinksInPath().path + "/"
        let localPrefixes = localProjectRoots.map { $0.resolvingSymlinksInPath().path + "/" }
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var result: [JSONLScanning.DiscoveredFile] = []
        var desktopOwners: [String: ClaudeSessionIdentity]?
        var identities: [String: ClaudeSessionIdentity?] = [:]

        func matches(_ identity: ClaudeSessionIdentity) -> Bool {
            guard case let .owned(org, account) = identity else { return false }
            return org == organizationID && (accountID == nil || account == accountID)
        }

        for file in files {
            guard !Task.isCancelled else { return nil }
            let path = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { continue }
            if path.hasPrefix(coworkPrefix) {
                let parts = path.dropFirst(coworkPrefix.count).split(separator: "/")
                if parts.count > 1, matches(.owned(
                    organizationID: parts[1].lowercased(), accountID: parts[0].lowercased()
                )) { result.append(file) }
                continue
            }
            guard let parent = ClaudeLogUsageScanner.owningSessionFile(for: file, filesByPath: byPath) else { continue }
            if identities[parent.path] == nil { identities[parent.path] = .some(identity(parent)) }
            guard let parsed = identities[parent.path], let owner = parsed else { return nil }
            switch owner {
            case .owned, .conflicted:
                if matches(owner) { result.append(file) }
            case .unattributed:
                // Desktop IDs are evidence only for this Mac's own project roots.
                if localPrefixes.contains(where: { path.hasPrefix($0) }) {
                    if desktopOwners == nil { desktopOwners = Self.desktopOwners(home: home) }
                    let sessionID = URL(fileURLWithPath: parent.path).deletingPathExtension().lastPathComponent.lowercased()
                    if let indexed = desktopOwners?[sessionID] {
                        if accountID != nil, matches(indexed) { result.append(file) }
                        continue
                    }
                }
                if allowsUnattributedSessions { result.append(file) }
            }
        }
        return result
    }

    private mutating func identity(_ file: JSONLScanning.DiscoveredFile) -> ClaudeSessionIdentity? {
        if let entry = cache[file.path], entry.size == file.size, entry.mtime == file.mtime { return entry.identity }
        do {
            guard let identity = ClaudeSessionIdentity.parse(try readData(URL(fileURLWithPath: file.path))),
                  !Task.isCancelled else { return nil }
            cache[file.path] = (file.size, file.mtime, identity)
            return identity
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "Failed to read session ownership from \(file.path): \(error)")
            return nil
        }
    }

    private static func desktopOwners(home: URL) -> [String: ClaudeSessionIdentity] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var result: [String: ClaudeSessionIdentity] = [:]
        for account in contents(root) where account.hasDirectoryPath {
            for org in contents(account) where org.hasDirectoryPath {
                let owner = ClaudeSessionIdentity.owned(
                    organizationID: org.lastPathComponent.lowercased(), accountID: account.lastPathComponent.lowercased()
                )
                for file in contents(org) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    do {
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        guard let data = try handle.read(upToCount: 512),
                              let header = String(data: data, encoding: .utf8),
                              let field = header.range(of: #""cliSessionId"\s*:\s*""#, options: .regularExpression),
                              let end = header[field.upperBound...].firstIndex(of: "\""),
                              let uuid = UUID(uuidString: String(header[field.upperBound..<end])) else { continue }
                        let id = uuid.uuidString.lowercased()
                        result[id] = result[id].map { $0 == owner ? owner : .conflicted } ?? owner
                    } catch {
                        AppLog.warn(LogTag.plugin("claude"), "Failed to read Desktop session index \(file.path): \(error)")
                    }
                }
            }
        }
        return result
    }

    private static func contents(_ directory: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "Failed to read Desktop session directory \(directory.path): \(error)")
            return []
        }
    }
}
