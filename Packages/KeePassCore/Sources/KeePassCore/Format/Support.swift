// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CZlib

public enum KDBXError: LocalizedError, Equatable {
    case notAKeePassFile
    case unsupportedVersion(UInt32)
    case kdb1NotSupported
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case invalidKDFParameters
    case invalidHeader(String)
    case invalidCredentials
    case corrupted(String)
    case invalidKeyOrIV
    case cryptoFailure(String)
    case compressionFailure
    case xmlParseFailure(String)
    case invalidKeyFile

    /// Messages are translated with the app's Localizable.strings (the English text is the key).
    /// Technical details stay in English.
    public var errorDescription: String? {
        switch self {
        case .notAKeePassFile: return localized("This file is not a KeePass database.")
        case .unsupportedVersion(let v): return localized("Unsupported KeePass database version (0x%@).", String(v, radix: 16))
        case .kdb1NotSupported: return localized("Legacy KeePass 1.x (.kdb) databases are not supported. Convert it to .kdbx with KeePass 2 first.")
        case .unsupportedCipher(let c): return localized("Unsupported encryption algorithm (%@). Twofish databases can be converted to AES or ChaCha20 in KeePass/KeePassXC.", c)
        case .unsupportedKDF(let k): return localized("Unsupported key derivation function (%@).", k)
        case .invalidKDFParameters: return localized("The key derivation parameters are invalid.")
        case .invalidHeader(let s): return localized("The database header is invalid: %@.", s)
        case .invalidCredentials: return localized("Wrong password or key file.")
        case .corrupted(let s): return localized("The database is corrupted: %@.", s)
        case .invalidKeyOrIV: return localized("Internal error: invalid key or IV length.")
        case .cryptoFailure(let s): return localized("Encryption error: %@.", s)
        case .compressionFailure: return localized("Could not decompress the database.")
        case .xmlParseFailure(let s): return localized("Could not read the database contents: %@.", s)
        case .invalidKeyFile: return localized("The key file could not be read.")
        }
    }
}

/// Looks up `key` in the app's Localizable.strings and fills in `%@` (or positional `%1$@`)
/// placeholders. Without a translation (for example in tests) the English key is used.
func localized(_ key: String, _ arguments: String...) -> String {
    fillPlaceholders(NSLocalizedString(key, comment: ""), arguments)
}

/// Replaces `%@`, `%1$@`… with `arguments` and `%%` with `%` (no other format specifiers are used).
func fillPlaceholders(_ format: String, _ arguments: [String]) -> String {
    guard format.contains("%") else { return format }
    var result = ""
    var next = 0
    var i = format.startIndex
    while i < format.endIndex {
        let c = format[i]
        let rest = format[format.index(after: i)...]
        guard c == "%" else {
            result.append(c)
            i = format.index(after: i)
            continue
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if rest.hasPrefix("%") {
            result.append("%")
            i = format.index(i, offsetBy: 2)
        } else if rest.hasPrefix("@") {
            if next < arguments.count { result += arguments[next] }
            next += 1
            i = format.index(i, offsetBy: 2)
        } else if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("$@"),
                  let n = Int(digits), n >= 1, n <= arguments.count {
            result += arguments[n - 1]
            i = format.index(i, offsetBy: 1 + digits.count + 2)
        } else {
            result.append(c)
            i = format.index(after: i)
        }
    }
    return result
}

public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator() // CSPRNG on every supported platform
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes)
    }

    public static func uniform(_ upperBound: Int) -> Int {
        var rng = SystemRandomNumberGenerator()
        return Int.random(in: 0..<upperBound, using: &rng)
    }
}

// MARK: - Byte reading / writing

struct ByteReader {
    let data: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { self.data = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.data = bytes }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset >= data.count }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= data.count else { throw KDBXError.corrupted("unexpected end of data") }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }
    mutating func data(_ n: Int) throws -> Data { Data(try bytes(n)) }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 { UInt16(truncatingIfNeeded: try uint(2)) }
    mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try uint(4)) }
    mutating func u64() throws -> UInt64 { try uint(8) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    private mutating func uint(_ n: Int) throws -> UInt64 {
        let b = try bytes(n)
        var v: UInt64 = 0
        for i in (0..<n).reversed() { v = v << 8 | UInt64(b[i]) }
        return v
    }
}

struct ByteWriter {
    private(set) var data = Data()
    mutating func append(_ d: Data) { data.append(d) }
    mutating func append(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { uint(UInt64(v), 2) }
    mutating func u32(_ v: UInt32) { uint(UInt64(v), 4) }
    mutating func u64(_ v: UInt64) { uint(v, 8) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    private mutating func uint(_ v: UInt64, _ n: Int) {
        for i in 0..<n { data.append(UInt8((v >> (UInt64(i) * 8)) & 0xff)) }
    }
}

extension Data {
    static func le(_ v: UInt64) -> Data { var w = ByteWriter(); w.u64(v); return w.data }
    static func le(_ v: UInt32) -> Data { var w = ByteWriter(); w.u32(v); return w.data }
    static func le(_ v: Int32) -> Data { var w = ByteWriter(); w.i32(v); return w.data }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.filter { !$0.isWhitespace })
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }

    /// Constant-time comparison.
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(self, other) { diff |= a ^ b }
        return diff == 0
    }
}

// MARK: - Gzip

enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 32, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw KDBXError.compressionFailure }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            repeat {
                try buffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw KDBXError.compressionFailure
                    }
                    output.append(outBuf.baseAddress!, count: chunk - Int(stream.avail_out))
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 { throw KDBXError.compressionFailure }
            } while status != Z_STREAM_END
        }
        return output
    }

    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                   zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw KDBXError.compressionFailure }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            repeat {
                try buffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw KDBXError.compressionFailure
                    }
                    output.append(outBuf.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}
