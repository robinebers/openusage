import Foundation

enum LogRedaction {
    static func redactLogMessage(_ message: String) -> String {
        message
            .replacing(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/, with: "[REDACTED]")
            .replacing(/(?:sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}/, with: "[REDACTED]")
            .replacing(/account=[^,\s]+/, with: "account=[REDACTED]")
            .replacing(/\/(?:Users|home|opt|private|var|tmp|Applications)\/[^\s"')]+/, with: "[PATH]")
    }
}
