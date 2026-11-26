// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The master key of a database: SHA-256 over the hashes of its components
/// (password and/or key file). Only the 32-byte result is kept in memory.
public struct CompositeKey: Equatable, Sendable {
    public let rawKey: Data

    /// - Parameters:
    ///   - password: `nil` means "no password component"; an empty string is a valid (empty) password.
    ///   - keyFileData: contents of a key file, if any.
    public init(password: String?, keyFileData: Data?) throws {
        var parts = Data()
        if let password { parts.append(Hash.sha256(Data(password.utf8))) }
        if let keyFileData { parts.append(try KeyFile.key(from: keyFileData)) }
        guard !parts.isEmpty else { throw KDBXError.invalidCredentials }
        rawKey = Hash.sha256(parts)
    }

    /// Restores a key previously obtained from `rawKey` (e.g. from the biometric keychain).
    public init(rawKey: Data) {
        self.rawKey = rawKey
    }
}

public enum KeyFile {
    /// Derives the 32-byte key from key file contents, supporting every format KeePass understands.
    public static func key(from data: Data) throws -> Data {
        guard !data.isEmpty else { throw KDBXError.invalidKeyFile }
        if let xmlKey = try parseXML(data) { return xmlKey }
        if data.count == 32 { return data }
        if data.count == 64, let s = String(data: data, encoding: .ascii), let hex = Data(hex: s), hex.count == 32 {
            return hex
        }
        return Hash.sha256(data)
    }

    /// Creates a new random key file in the KeePass 2.x XML (version 2.0) format.
    public static func generate() -> Data {
        let key = SecureRandom.bytes(32)
        let hash = Hash.sha256(key).prefix(4).hexString.uppercased()
        let hex = key.hexString.uppercased()
        var groups = [String]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 8)
            groups.append(String(hex[i..<j]))
            i = j
        }
        let lines = stride(from: 0, to: groups.count, by: 4).map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
        \t<Meta>
        \t\t<Version>2.0</Version>
        \t</Meta>
        \t<Key>
        \t\t<Data Hash="\(hash)">
        \t\t\t\(lines.joined(separator: "\n\t\t\t"))
        \t\t</Data>
        \t</Key>
        </KeyFile>

        """
        return Data(xml.utf8)
    }

    private static func parseXML(_ data: Data) throws -> Data? {
        guard data.count < 64 * 1024,
              let head = String(data: data.prefix(256), encoding: .utf8),
              head.contains("<KeyFile") || head.contains("<?xml") else { return nil }
        guard let root = try? XMLTree.parse(data, protectedStream: nil),
              root.name == "KeyFile" else { return nil }
        let version = root.child("Meta")?.child("Version")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let dataNode = root.child("Key")?.child("Data") else { return nil }
        let text = dataNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("2") {
            guard let key = Data(hex: text), key.count == 32 else { throw KDBXError.invalidKeyFile }
            if let hashAttr = dataNode.attribute("Hash") {
                guard let expected = Data(hex: hashAttr), Hash.sha256(key).prefix(4) == expected else {
                    throw KDBXError.invalidKeyFile
                }
            }
            return key
        } else {
            guard let key = Data(base64Encoded: text), key.count == 32 else { throw KDBXError.invalidKeyFile }
            return key
        }
    }
}
