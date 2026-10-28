import Foundation

public enum ContainingAppBundle {
    public static func url(for executableURL: URL) -> URL? {
        var candidate = executableURL.resolvingSymlinksInPath().standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
