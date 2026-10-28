import Darwin
import Foundation
import OpenUsage

@main
struct OpenUsageCLI {
    @MainActor
    static func main() {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.showHelp {
                print(help)
                return
            }

            let app = AppBundleLocator.locate()
            if arguments.showVersion {
                print(app.version.map { "openusage \($0)" } ?? "openusage (development build)")
                return
            }

            guard let defaults = UserDefaults(suiteName: app.bundleIdentifier) else {
                fail("Could not open the OpenUsage settings domain.", code: 4)
            }
            let result = try UsageReader(userDefaults: defaults).read(providerID: arguments.providerID)
            FileHandle.standardOutput.write(result.data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !result.hasSnapshots {
                fail("nothing fetched yet; open OpenUsage and add or refresh an account", code: 4)
            }
        } catch CLIError.usage(let message) {
            fail("\(message)\nRun 'openusage --help' for usage.", code: 2)
        } catch UsageReaderError.unknownProvider(let providerID) {
            fail("Unknown provider: \(providerID)", code: 2)
        } catch {
            fail(error.localizedDescription, code: 4)
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("openusage: \(message)\n".utf8))
        exit(code)
    }

    private static let help = """
    Usage: openusage [provider]

    Print the usage OpenUsage last fetched, as openusage.limits.v1 JSON, and exit. The app refreshes
    on its own schedule; this command never refreshes or signs in.

    provider      An account id (codex@1a2b3c4d) or a provider kind (claude, codex) for every
                  account of that kind. Omit it for every account.

    Options:
      -v, --version
      -h, --help

    Exit codes: 0 printed, 2 bad arguments or unknown provider, 4 nothing fetched yet.
    """
}
