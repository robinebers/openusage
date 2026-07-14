import CryptoKit
import Foundation

enum FactoryAuthCrypto {
    static func decrypt(envelope: String, keyBase64: String) throws -> String {
        let parts = envelope.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw FactoryAuthError.invalidCredentialData
        }
        guard let key = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.count == 32,
              let nonceData = Data(base64Encoded: String(parts[0])),
              let tag = Data(base64Encoded: String(parts[1])),
              let ciphertext = Data(base64Encoded: String(parts[2]))
        else {
            throw FactoryAuthError.invalidCredentialData
        }

        let symmetricKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw FactoryAuthError.invalidCredentialData
        }
        return text
    }

    static func encrypt(plaintext: String, keyBase64: String) throws -> String {
        guard let key = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.count == 32
        else {
            throw FactoryAuthError.invalidCredentialData
        }

        let symmetricKey = SymmetricKey(data: key)
        let nonceData = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(Data(plaintext.utf8), using: symmetricKey, nonce: nonceData)
        return [
            Data(sealedBox.nonce).base64EncodedString(),
            sealedBox.tag.base64EncodedString(),
            sealedBox.ciphertext.base64EncodedString()
        ].joined(separator: ":")
    }
}
