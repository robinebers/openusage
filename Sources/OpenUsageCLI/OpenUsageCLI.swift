import Darwin
import Foundation
import OpenUsage

@main
struct OpenUsageCLI {
    static func main() async {
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
                throw CLIError.appDefaultsUnavailable
            }

            if arguments.claimReset {
                guard arguments.providerID == "codex" else {
                    throw CLIError.usage("--claim-reset claims a Codex reset credit: run 'openusage codex --claim-reset'.")
                }
                let claim = await CodexResetClaimRunner(userDefaults: defaults).claimNextAvailableCredit()
                FileHandle.standardOutput.write(claim.data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                claim.warnings.forEach { writeError("warning: \($0)") }
                switch claim.status {
                case .claimed, .nothingToReset:
                    // Exit 0 even when the post-claim refresh warned: the claim itself landed, and a
                    // non-zero exit would invite scripted retries — a new process is a new idempotency
                    // key, so a retry could spend a second credit.
                    break
                case .noCredit:
                    exit(3)
                case .failed:
                    exit(4)
                }
                return
            }

            let result = try await UsageReader(userDefaults: defaults).read(
                providerID: arguments.providerID,
                force: arguments.force
            )
            FileHandle.standardOutput.write(result.data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !result.warnings.isEmpty {
                result.warnings.forEach { writeError("warning: \($0)") }
                exit(4)
            }
        } catch CLIError.usage(let message) {
            fail("\(message)\nRun 'openusage --help' for usage.", code: 2)
        } catch CLIError.appDefaultsUnavailable {
            fail("Could not open the OpenUsage settings domain.", code: 4)
        } catch UsageReaderError.noCachedSnapshot(let providerID) {
            fail("No cached usage for \(providerID). Run with --force to fetch it.", code: 3)
        } catch UsageReaderError.unknownProvider(let providerID) {
            fail("Unknown provider: \(providerID)", code: 2)
        } catch {
            fail(error.localizedDescription, code: 4)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("openusage: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        writeError(message)
        exit(code)
    }

    private static let help = """
    Usage: openusage [provider] [--force] [--claim-reset]

    Read limits through OpenUsage's shared five-minute cache and exit. Output is always JSON.

    Options:
      --force        Refresh even when the shared cache is still fresh
      --claim-reset  Spend the next-to-expire Codex rate-limit reset credit (codex only).
                     Claims immediately, without confirmation — see docs/cli.md before scripting retries
      -v, --version
      -h, --help
    """
}
