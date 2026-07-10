import Foundation
import OpenUsageCore

@MainActor
@main
enum E2EEntry {
    static func main() async {
        await Phase2E2EHarness.run()
    }
}
