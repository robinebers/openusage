import Foundation

enum MuseCookieError: Error, Equatable {
    case unsupportedVersion
    case decryptionFailed
}

/// Chromium cookie decryption for the macOS Keychain scheme: the cookie value is
/// `v10`/`v11` + AES-128-CBC ciphertext, keyed by PBKDF2-HMAC-SHA1 over the browser's
/// Safe Storage password. Ported from lassejlv's upstream PR #1248
/// (robinebers/openusage): the crypto itself is `ClaudeDesktopAuthStore`'s proven pair
/// (Electron's `safeStorage` uses this exact Chromium scheme); this wrapper only adapts
/// the sqlite-CLI hex encoding and the `v11` version tag, which shares the `v10` scheme.
enum MuseCookieDecrypt {
    static func decryptChromiumCookie(hex: String, password: String) throws -> String {
        guard let encrypted = Data(museHex: hex), encrypted.count > 3 else {
            throw MuseCookieError.unsupportedVersion
        }
        var bytes = encrypted
        let prefix = bytes.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else {
            throw MuseCookieError.unsupportedVersion
        }
        if prefix == Data("v11".utf8) {
            bytes.replaceSubrange(0..<3, with: Data("v10".utf8))
        }
        do {
            let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
            let plaintext = try ClaudeDesktopAuthStore.decrypt(bytes, key: key)
            guard let value = String(data: plaintext, encoding: .utf8), !value.isEmpty else {
                throw MuseCookieError.decryptionFailed
            }
            return value
        } catch let error as MuseCookieError {
            throw error
        } catch {
            throw MuseCookieError.decryptionFailed
        }
    }
}

extension Data {
    init?(museHex: String) {
        let text = museHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count.isMultiple(of: 2), !text.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// Minimal `Cookies.binarycookies` reader (Safari): enough to find one cookie by name and
/// domain. Malformed input yields nil — never a throw — so a corrupt store reads as absent.
enum MuseBinaryCookies {
    static func cookie(named name: String, domainHint: String, in data: Data) -> String? {
        for (url, cookieName, value) in allCookies(data) where url.contains(domainHint) && cookieName == name {
            return value
        }
        return nil
    }

    /// Whether `data` is at least structurally a binarycookies store (magic + sane page
    /// count). Lets callers tell "no such cookie" apart from "store corrupt".
    static func isWellFormed(_ data: Data) -> Bool {
        guard data.count >= 8, data[0..<4] == Data("cook".utf8) else { return false }
        let pageCount = Int(data[museU32BE: 4])
        return pageCount > 0 && pageCount < 10_000 && data.count >= 8 + 4 * pageCount
    }

    static func allCookies(_ data: Data) -> [(url: String, name: String, value: String)] {
        var cookies: [(String, String, String)] = []
        guard data.count >= 8, data[0..<4] == Data("cook".utf8) else { return [] }
        let pageCount = Int(data[museU32BE: 4])
        guard pageCount > 0, pageCount < 10_000 else { return [] }
        var offset = 8 + 4 * pageCount
        guard data.count >= offset else { return [] }
        for index in 0..<pageCount {
            let pageSize = Int(data[museU32BE: 8 + 4 * index])
            guard pageSize >= 12, offset + pageSize <= data.count else { return cookies }
            let page = data[offset..<(offset + pageSize)]
            offset += pageSize
            guard page.count >= 12, page[page.startIndex..<(page.startIndex + 4)] == Data([0, 0, 1, 0]) else { continue }
            let cookieCount = Int(page[museU32LE: page.startIndex + 8])
            guard cookieCount >= 0, cookieCount < 100_000 else { continue }
            for slot in 0..<cookieCount {
                let entry = page.startIndex + 12 + 4 * slot
                guard entry + 4 <= page.endIndex else { break }
                let recordOffset = page.startIndex + Int(page[museU32LE: entry])
                guard recordOffset < page.endIndex,
                      let parsed = parseRecord(page, at: recordOffset)
                else { continue }
                cookies.append(parsed)
            }
        }
        return cookies
    }

    private static func parseRecord(_ page: Data, at base: Data.Index) -> (String, String, String)? {
        guard base + 28 <= page.endIndex else { return nil }
        let urlOffset = base + Int(page[museU32LE: base + 16])
        let nameOffset = base + Int(page[museU32LE: base + 20])
        let valueOffset = base + Int(page[museU32LE: base + 28])
        guard let url = cString(page, at: urlOffset),
              let name = cString(page, at: nameOffset),
              let value = cString(page, at: valueOffset)
        else { return nil }
        return (url, name, value)
    }

    private static func cString(_ page: Data, at offset: Data.Index) -> String? {
        guard offset < page.endIndex else { return nil }
        var end = offset
        while end < page.endIndex, page[end] != 0 { end = page.index(after: end) }
        guard end < page.endIndex else { return nil }
        return String(data: page[offset..<end], encoding: .utf8)
    }
}

private extension Data {
    /// Big-endian UInt32 at an absolute offset (callers bounds-check first).
    subscript(museU32BE offset: Index) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[index(offset, offsetBy: 1)]) << 16)
            | (UInt32(self[index(offset, offsetBy: 2)]) << 8) | UInt32(self[index(offset, offsetBy: 3)])
    }

    /// Little-endian UInt32 at an absolute offset (callers bounds-check first).
    subscript(museU32LE offset: Index) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[index(offset, offsetBy: 1)]) << 8)
            | (UInt32(self[index(offset, offsetBy: 2)]) << 16) | (UInt32(self[index(offset, offsetBy: 3)]) << 24)
    }
}
