// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// MARK: - VariantDictionary (KDBX 4 typed key/value map)

public struct VariantDictionary: Equatable {
    public enum Value: Equatable {
        case uint32(UInt32), uint64(UInt64), bool(Bool), int32(Int32), int64(Int64), string(String), bytes(Data)
    }

    public private(set) var items: [(String, Value)] = []

    public init() {}

    public static func == (a: VariantDictionary, b: VariantDictionary) -> Bool {
        a.items.count == b.items.count && zip(a.items, b.items).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public subscript(key: String) -> Value? {
        get { items.first { $0.0 == key }?.1 }
        set {
            if let idx = items.firstIndex(where: { $0.0 == key }) {
                if let newValue { items[idx].1 = newValue } else { items.remove(at: idx) }
            } else if let newValue {
                items.append((key, newValue))
            }
        }
    }

    func uint64(_ key: String) -> UInt64? {
        switch self[key] {
        case .uint64(let v): return v
        case .uint32(let v): return UInt64(v)
        case .int64(let v): return UInt64(clamping: v)
        case .int32(let v): return UInt64(clamping: v)
        default: return nil
        }
    }
    func bytes(_ key: String) -> Data? { if case .bytes(let d) = self[key] { return d }; return nil }

    init(data: Data) throws {
        var r = ByteReader(data)
        let version = try r.u16()
        guard version & 0xFF00 == 0x0100 else { throw KDBXError.invalidHeader("variant dictionary version") }
        while true {
            let type = try r.u8()
            if type == 0 { break }
            let keyLen = Int(try r.i32())
            guard let key = String(data: try r.data(keyLen), encoding: .utf8) else {
                throw KDBXError.invalidHeader("variant dictionary key")
            }
            let valLen = Int(try r.i32())
            var v = ByteReader(try r.bytes(valLen))
            let value: Value
            switch type {
            case 0x04: value = .uint32(try v.u32())
            case 0x05: value = .uint64(try v.u64())
            case 0x08: value = .bool(try v.u8() != 0)
            case 0x0C: value = .int32(try v.i32())
            case 0x0D: value = .int64(Int64(bitPattern: try v.u64()))
            case 0x18: value = .string(String(decoding: v.data, as: UTF8.self))
            case 0x42: value = .bytes(Data(v.data))
            default: continue // unknown types are skipped
            }
            items.append((key, value))
        }
    }

    func serialized() -> Data {
        var w = ByteWriter()
        w.u16(0x0100)
        for (key, value) in items {
            let keyData = Data(key.utf8)
            var vw = ByteWriter()
            let type: UInt8
            switch value {
            case .uint32(let v): type = 0x04; vw.u32(v)
            case .uint64(let v): type = 0x05; vw.u64(v)
            case .bool(let v): type = 0x08; vw.u8(v ? 1 : 0)
            case .int32(let v): type = 0x0C; vw.i32(v)
            case .int64(let v): type = 0x0D; vw.u64(UInt64(bitPattern: v))
            case .string(let s): type = 0x18; vw.append(Data(s.utf8))
            case .bytes(let d): type = 0x42; vw.append(d)
            }
            w.u8(type)
            w.i32(Int32(keyData.count)); w.append(keyData)
            w.i32(Int32(vw.data.count)); w.append(vw.data)
        }
        w.u8(0)
        return w.data
    }
}

// MARK: - Ciphers

public enum Cipher: String, CaseIterable, Identifiable {
    case aes256, chacha20

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .aes256: return "AES-256"
        case .chacha20: return "ChaCha20"
        }
    }

    static let aesUUID = UUID(uuidString: "31C1F2E6-BF71-4350-BE58-05216AFC5AFF")!
    static let chachaUUID = UUID(uuidString: "D6038A2B-8B6F-4CB5-A524-339A31DBB59A")!
    static let twofishUUID = UUID(uuidString: "AD68F29F-576F-4BB9-A36A-D47AF965346C")!

    var uuid: UUID { self == .aes256 ? Cipher.aesUUID : Cipher.chachaUUID }
    var ivLength: Int { self == .aes256 ? 16 : 12 }

    init(uuid: UUID) throws {
        switch uuid {
        case Cipher.aesUUID: self = .aes256
        case Cipher.chachaUUID: self = .chacha20
        case Cipher.twofishUUID: throw KDBXError.unsupportedCipher("Twofish")
        default: throw KDBXError.unsupportedCipher(uuid.uuidString)
        }
    }

    func encrypt(key: Data, iv: Data, _ data: Data) throws -> Data {
        switch self {
        case .aes256: return try AESCipher.cbcEncrypt(key: key, iv: iv, plaintext: data)
        case .chacha20: return try ChaCha20(key: key, nonce: iv).xor(data)
        }
    }

    func decrypt(key: Data, iv: Data, _ data: Data) throws -> Data {
        switch self {
        case .aes256: return try AESCipher.cbcDecrypt(key: key, iv: iv, ciphertext: data)
        case .chacha20: return try ChaCha20(key: key, nonce: iv).xor(data)
        }
    }
}

// MARK: - Key derivation

public enum KDFParameters: Equatable {
    case aes(rounds: UInt64, seed: Data)
    case argon2(Argon2Parameters)

    public struct Argon2Parameters: Equatable {
        public var variant: Argon2.Variant // .d or .id
        public var salt: Data
        public var iterations: UInt64
        public var memoryBytes: UInt64
        public var parallelism: UInt32
        public var version: UInt32 = 0x13
        public var secret: Data? = nil
        public var associatedData: Data? = nil

        public init(variant: Argon2.Variant, salt: Data, iterations: UInt64, memoryBytes: UInt64,
                    parallelism: UInt32, version: UInt32 = 0x13) {
            self.variant = variant; self.salt = salt; self.iterations = iterations
            self.memoryBytes = memoryBytes; self.parallelism = parallelism; self.version = version
        }
    }

    static let aesKdfUUID = UUID(uuidString: "C9D9F39A-628A-4460-BF74-0D08C18A4FEA")!
    static let argon2dUUID = UUID(uuidString: "EF636DDF-8C29-444B-91F7-A9A403E30A0C")!
    static let argon2idUUID = UUID(uuidString: "9E298B19-56DB-4773-B23D-FC3EC6F0A1E6")!

    /// Sensible defaults for new databases on a phone.
    public static func defaultArgon2id() -> KDFParameters {
        .argon2(Argon2Parameters(variant: .id, salt: SecureRandom.bytes(32), iterations: 4,
                                 memoryBytes: 64 * 1024 * 1024, parallelism: 2))
    }

    public static func defaultAES() -> KDFParameters {
        .aes(rounds: 2_000_000, seed: SecureRandom.bytes(32))
    }

    public var displayName: String {
        switch self {
        case .aes: return "AES-KDF"
        case .argon2(let p): return p.variant == .id ? "Argon2id" : "Argon2d"
        }
    }

    /// Same algorithm and cost, new random salt/seed.
    public func withNewSalt() -> KDFParameters {
        switch self {
        case .aes(let rounds, _): return .aes(rounds: rounds, seed: SecureRandom.bytes(32))
        case .argon2(var p): p.salt = SecureRandom.bytes(32); return .argon2(p)
        }
    }

    init(dictionary d: VariantDictionary) throws {
        guard let uuidBytes = d.bytes("$UUID"), uuidBytes.count == 16 else { throw KDBXError.invalidKDFParameters }
        let uuid = UUID(data: uuidBytes)
        switch uuid {
        case KDFParameters.aesKdfUUID:
            guard let rounds = d.uint64("R"), let seed = d.bytes("S"), seed.count == 32 else {
                throw KDBXError.invalidKDFParameters
            }
            self = .aes(rounds: rounds, seed: seed)
        case KDFParameters.argon2dUUID, KDFParameters.argon2idUUID:
            guard let salt = d.bytes("S"), let iterations = d.uint64("I"), let memory = d.uint64("M"),
                  let parallelism = d.uint64("P") else { throw KDBXError.invalidKDFParameters }
            var p = Argon2Parameters(variant: uuid == KDFParameters.argon2dUUID ? .d : .id, salt: salt,
                                     iterations: iterations, memoryBytes: memory,
                                     parallelism: UInt32(clamping: parallelism),
                                     version: UInt32(clamping: d.uint64("V") ?? 0x13))
            p.secret = d.bytes("K")
            p.associatedData = d.bytes("A")
            self = .argon2(p)
        default:
            throw KDBXError.unsupportedKDF(uuid.uuidString)
        }
    }

    var dictionary: VariantDictionary {
        var d = VariantDictionary()
        switch self {
        case .aes(let rounds, let seed):
            d["$UUID"] = .bytes(KDFParameters.aesKdfUUID.data)
            d["R"] = .uint64(rounds)
            d["S"] = .bytes(seed)
        case .argon2(let p):
            d["$UUID"] = .bytes((p.variant == .d ? KDFParameters.argon2dUUID : KDFParameters.argon2idUUID).data)
            d["S"] = .bytes(p.salt)
            d["P"] = .uint32(p.parallelism)
            d["M"] = .uint64(p.memoryBytes)
            d["I"] = .uint64(p.iterations)
            d["V"] = .uint32(p.version)
            if let k = p.secret { d["K"] = .bytes(k) }
            if let a = p.associatedData { d["A"] = .bytes(a) }
        }
        return d
    }

    /// Derives the 32-byte transformed key from the composite key.
    public func transform(_ compositeKey: Data) throws -> Data {
        switch self {
        case .aes(let rounds, let seed):
            let t = try AESCipher.ecbEncryptRounds(key: seed, data: compositeKey, rounds: rounds)
            return Hash.sha256(t)
        case .argon2(let p):
            guard p.iterations <= UInt64(UInt32.max), p.memoryBytes / 1024 <= UInt64(UInt32.max) else {
                throw KDBXError.invalidKDFParameters
            }
            return try Argon2.hash(password: compositeKey, salt: p.salt, secret: p.secret ?? Data(),
                                   associatedData: p.associatedData ?? Data(),
                                   iterations: UInt32(p.iterations), memoryKiB: UInt32(p.memoryBytes / 1024),
                                   parallelism: p.parallelism, outputLength: 32, variant: p.variant,
                                   version: p.version)
        }
    }
}

// MARK: - UUID <-> bytes

extension UUID {
    init(data: Data) {
        var bytes = [UInt8](data)
        if bytes.count < 16 { bytes += [UInt8](repeating: 0, count: 16 - bytes.count) }
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    public static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// KeePass stores UUIDs as base64 of their 16 raw bytes.
    var keepassBase64: String { data.base64EncodedString() }

    init?(keepassBase64 s: String) {
        guard let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 16 else {
            return nil
        }
        self.init(data: d)
    }
}
