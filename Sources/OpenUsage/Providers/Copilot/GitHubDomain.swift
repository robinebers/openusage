import Foundation

/// Where a Copilot seat signs in: github.com, or a company's GitHub Enterprise Cloud domain on GHE.com.
/// Self-hosted GitHub Enterprise Server is not supported.
enum GitHubDomain: Hashable, Sendable {
    case github
    /// A `<name>.ghe.com` domain.
    case enterprise(String)

    static let invalidMessage = "OpenUsage works with GitHub Enterprise on GHE.com. Enter an address like octocorp.ghe.com."

    init(saved domain: String?) {
        self = domain.map(Self.enterprise) ?? .github
    }

    /// Reads a typed or pasted address. It trims and lowercases it and drops the scheme and path, so a
    /// pasted link works. Blank or github.com is github.com, and a bare name is `<name>.ghe.com`. Any
    /// other address is not a GHE.com domain.
    init?(parsing input: String) {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { !"/?#".contains($0) })
        if host.isEmpty || host == "github.com" || host == "www.github.com" {
            self = .github
            return
        }
        if !host.contains(".") { host += ".ghe.com" }
        guard host.hasSuffix(".ghe.com") else { return nil }
        let name = host.dropLast(".ghe.com".count)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasSuffix("-"),
              name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return nil }
        self = .enterprise(host)
    }

    /// What an account saves: github.com saves none.
    var saved: String? {
        guard case .enterprise(let domain) = self else { return nil }
        return domain
    }

    var host: String { saved ?? "github.com" }

    func webURL(_ path: String) -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    /// GitHub's API lives on `api.` of the same domain: api.github.com, or api.<name>.ghe.com.
    func apiURL(_ path: String) -> URL {
        URL(string: "https://api.\(host)\(path)")!
    }
}
