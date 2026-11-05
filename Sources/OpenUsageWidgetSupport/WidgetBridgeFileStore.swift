import Foundation

public enum WidgetBridgeFileError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
}

/// Atomic, replace-in-place persistence shared by the host and widget extension. A failed encode or
/// write leaves the previous file untouched because `Data.write(.atomic)` commits via rename.
public struct WidgetBridgeFileStore: Sendable {
    public static let fileName = "widget-bridge-v1.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(appGroupContainerURL: URL) {
        self.init(fileURL: appGroupContainerURL.appendingPathComponent(Self.fileName))
    }

    public func read() throws -> WidgetBridgeDocument? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let document = try Self.decoder.decode(WidgetBridgeDocument.self, from: data)
        guard document.schemaVersion == WidgetBridgeDocument.currentSchemaVersion else {
            throw WidgetBridgeFileError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    public func write(_ document: WidgetBridgeDocument) throws {
        guard document.schemaVersion == WidgetBridgeDocument.currentSchemaVersion else {
            throw WidgetBridgeFileError.unsupportedSchema(document.schemaVersion)
        }
        let data = try Self.encoder.encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
