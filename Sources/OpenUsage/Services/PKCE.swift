import CryptoKit
import Foundation

struct PKCEPair: Sendable, Equatable {
    let verifier: String
    let challenge: String
}

enum PKCE {
    static func generate() -> PKCEPair {
        let verifier = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
