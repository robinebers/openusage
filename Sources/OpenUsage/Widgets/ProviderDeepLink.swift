import Foundation

enum ProviderDeepLink: Equatable, Sendable {
    case provider(String)
    case recovery

    static func parse(_ url: URL, expectedScheme: String, knownProviderIDs: Set<String>) -> Self? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == expectedScheme.lowercased(),
              scheme == "openusage" || scheme == "openusage-dev",
              components.host?.lowercased() == "provider",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count <= 1 else { return nil }
        guard let id = path.first.map(String.init), knownProviderIDs.contains(id) else { return .recovery }
        return .provider(id)
    }
}
