// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Reads KDBX 3.1 / 4.0 / 4.1 files and writes KDBX 4.x.
public enum KDBX {
    public static let version31: UInt32 = 0x0003_0001
    public static let version40: UInt32 = 0x0004_0000
    public static let version41: UInt32 = 0x0004_0001

    static let signature1: UInt32 = 0x9AA2_D903
    static let signature2: UInt32 = 0xB54B_FB67
    static let signature2Pre: UInt32 = 0xB54B_FB66
    static let signatureKDB1: UInt32 = 0xB54B_FB65

    private enum HeaderField: UInt8 {
        case end = 0, comment, cipherID, compressionFlags, masterSeed, transformSeed, transformRounds,
             encryptionIV, protectedStreamKey, streamStartBytes, innerRandomStreamID, kdfParameters, publicCustomData
    }

    private enum InnerHeaderField: UInt8 {
        case end = 0, innerRandomStreamID, innerRandomStreamKey, binary
    }

    private static let salsaNonce = Data([0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])

    public static func isKeePassFile(_ data: Data) -> Bool {
        var r = ByteReader(data.prefix(8))
        guard let s1 = try? r.u32(), let s2 = try? r.u32() else { return false }
        return s1 == signature1 && (s2 == signature2 || s2 == signature2Pre || s2 == signatureKDB1)
    }

    // MARK: - Reading

    public static func open(_ data: Data, key: CompositeKey) throws -> Database {
        var r = ByteReader(data)
        guard (try? r.u32()) == signature1 else { throw KDBXError.notAKeePassFile }
        let sig2 = try r.u32()
        if sig2 == signatureKDB1 { throw KDBXError.kdb1NotSupported }
        guard sig2 == signature2 || sig2 == signature2Pre else { throw KDBXError.notAKeePassFile }
        let version = try r.u32()
        let major = version >> 16
        guard major >= 2 && major <= 4 else { throw KDBXError.unsupportedVersion(version) }
        let isV4 = major == 4

        var fields: [UInt8: Data] = [:]
        while true {
            let id = try r.u8()
            let size = isV4 ? Int(try r.u32()) : Int(try r.u16())
            let value = try r.data(size)
            if id == HeaderField.end.rawValue { break }
            fields[id] = value
        }
        let headerBytes = Data(data.prefix(r.offset))

        guard let cipherBytes = fields[HeaderField.cipherID.rawValue], cipherBytes.count == 16 else {
            throw KDBXError.invalidHeader("missing cipher")
        }
        let cipher = try Cipher(uuid: UUID(data: cipherBytes))
        var compression = false
        if let c = fields[HeaderField.compressionFlags.rawValue] {
            var cr = ByteReader(c)
            let flag = try cr.u32()
            guard flag <= 1 else { throw KDBXError.invalidHeader("unknown compression") }
            compression = flag == 1
        }
        guard let masterSeed = fields[HeaderField.masterSeed.rawValue], masterSeed.count == 32 else {
            throw KDBXError.invalidHeader("missing master seed")
        }
        guard let iv = fields[HeaderField.encryptionIV.rawValue], iv.count == cipher.ivLength else {
            throw KDBXError.invalidHeader("invalid encryption IV")
        }

        let kdf: KDFParameters
        if isV4 {
            guard let kdfData = fields[HeaderField.kdfParameters.rawValue] else { throw KDBXError.invalidHeader("missing KDF") }
            kdf = try KDFParameters(dictionary: try VariantDictionary(data: kdfData))
        } else {
            guard let seed = fields[HeaderField.transformSeed.rawValue], seed.count == 32,
                  let roundsData = fields[HeaderField.transformRounds.rawValue] else {
                throw KDBXError.invalidHeader("missing transform parameters")
            }
            var rr = ByteReader(roundsData)
            kdf = .aes(rounds: try rr.u64(), seed: seed)
        }

        let transformed = try kdf.transform(key.rawKey)
        let masterKey = Hash.sha256(masterSeed, transformed)

        let payload: Data
        var binaries: [Int: Attachment] = [:]
        var protectedStream: KeystreamCipher?

        if isV4 {
            let storedHash = try r.data(32)
            guard Hash.sha256(headerBytes) == storedHash else { throw KDBXError.corrupted("header checksum mismatch") }
            let storedHMAC = try r.data(32)
            let hmacBase = Hash.sha512(masterSeed, transformed, Data([1]))
            let headerHMAC = Hash.hmacSHA256(key: blockHMACKey(UInt64.max, base: hmacBase), data: headerBytes)
            guard headerHMAC.constantTimeEquals(storedHMAC) else { throw KDBXError.invalidCredentials }

            let encrypted = try readHMACBlocks(&r, base: hmacBase)
            let decrypted = try cipher.decrypt(key: masterKey, iv: iv, encrypted)
            let plain = compression ? try Gzip.decompress(decrypted) : decrypted

            var ir = ByteReader(plain)
            var streamID: UInt32 = 0
            var streamKey = Data()
            var binaryIndex = 0
            while true {
                let id = try ir.u8()
                let size = Int(try ir.i32())
                guard size >= 0 else { throw KDBXError.corrupted("inner header") }
                let value = try ir.data(size)
                switch InnerHeaderField(rawValue: id) {
                case .end: break
                case .innerRandomStreamID:
                    var vr = ByteReader(value); streamID = try vr.u32()
                case .innerRandomStreamKey:
                    streamKey = value
                case .binary:
                    guard !value.isEmpty else { throw KDBXError.corrupted("binary") }
                    binaries[binaryIndex] = Attachment(name: "", data: Data(value.dropFirst()),
                                                       isProtected: value.first! & 1 == 1)
                    binaryIndex += 1
                case .none: break
                }
                if id == InnerHeaderField.end.rawValue { break }
            }
            protectedStream = try makeInnerStream(id: streamID, key: streamKey)
            payload = Data(plain.suffix(from: plain.startIndex + ir.offset))
        } else {
            guard let startBytes = fields[HeaderField.streamStartBytes.rawValue] else {
                throw KDBXError.invalidHeader("missing stream start bytes")
            }
            let encrypted = Data(data.suffix(from: data.startIndex + r.offset))
            let decrypted = try cipher.decrypt(key: masterKey, iv: iv, encrypted)
            guard decrypted.count >= startBytes.count,
                  decrypted.prefix(startBytes.count).constantTimeEquals(startBytes) else {
                throw KDBXError.invalidCredentials
            }
            var br = ByteReader(decrypted.suffix(from: decrypted.startIndex + startBytes.count))
            let unhashed = try readHashedBlocks(&br)
            payload = compression ? try Gzip.decompress(unhashed) : unhashed
            var idData = fields[HeaderField.innerRandomStreamID.rawValue] ?? Data([0, 0, 0, 0])
            if idData.count < 4 { idData += Data(repeating: 0, count: 4 - idData.count) }
            var idr = ByteReader(idData)
            protectedStream = try makeInnerStream(id: try idr.u32(),
                                                  key: fields[HeaderField.protectedStreamKey.rawValue] ?? Data())
        }

        let xml = try XMLTree.parse(payload, protectedStream: protectedStream)
        let db = Database(meta: Meta(), root: KPGroup(name: ""),
                          settings: DatabaseSettings(formatVersion: version, cipher: cipher,
                                                     compression: compression, kdf: kdf))
        db.publicCustomData = fields[HeaderField.publicCustomData.rawValue]
        try XMLMapping.read(document: xml, binaries: binaries, into: db)
        db.transformCache = (key.rawKey, kdf, transformed)
        return db
    }

    private static func makeInnerStream(id: UInt32, key: Data) throws -> KeystreamCipher? {
        switch id {
        case 0: return nil
        case 2: return try Salsa20(key: Hash.sha256(key), nonce: salsaNonce)
        case 3:
            let h = Hash.sha512(key)
            return try ChaCha20(key: h.prefix(32), nonce: h.subdata(in: h.startIndex + 32..<h.startIndex + 44))
        default: throw KDBXError.invalidHeader("unsupported inner stream \(id)")
        }
    }

    private static func blockHMACKey(_ index: UInt64, base: Data) -> Data {
        Hash.sha512(Data.le(index), base)
    }

    private static func readHMACBlocks(_ r: inout ByteReader, base: Data) throws -> Data {
        var out = Data()
        var index: UInt64 = 0
        while true {
            let hmac = try r.data(32)
            let size = try r.i32()
            guard size >= 0 else { throw KDBXError.corrupted("negative block size") }
            let block = try r.data(Int(size))
            var msg = Data.le(index)
            msg.append(Data.le(size))
            msg.append(block)
            let expected = Hash.hmacSHA256(key: blockHMACKey(index, base: base), data: msg)
            guard expected.constantTimeEquals(hmac) else { throw KDBXError.corrupted("block \(index) failed integrity check") }
            if size == 0 { break }
            out.append(block)
            index += 1
        }
        return out
    }

    private static func readHashedBlocks(_ r: inout ByteReader) throws -> Data {
        var out = Data()
        var expectedIndex: UInt32 = 0
        while true {
            let index = try r.u32()
            guard index == expectedIndex else { throw KDBXError.corrupted("block order") }
            let hash = try r.data(32)
            let size = try r.i32()
            guard size >= 0 else { throw KDBXError.corrupted("negative block size") }
            if size == 0 {
                guard hash.allSatisfy({ $0 == 0 }) else { throw KDBXError.corrupted("final block") }
                break
            }
            let block = try r.data(Int(size))
            guard Hash.sha256(block) == hash else { throw KDBXError.corrupted("block \(index) failed integrity check") }
            out.append(block)
            expectedIndex += 1
        }
        return out
    }

    // MARK: - Writing

    /// Serialises the database as KDBX 4. Reuses the cached derived key when the
    /// master key and KDF settings are unchanged, so saving is fast.
    public static func save(_ db: Database, key: CompositeKey) throws -> Data {
        let settings = db.settings
        let v41 = XMLMapping.needsVersion41(db) || settings.formatVersion >= version41
        let version = v41 ? version41 : version40

        let transformed: Data
        if let cache = db.transformCache, cache.rawKey == key.rawKey, cache.kdf == settings.kdf {
            transformed = cache.transformed
        } else {
            transformed = try settings.kdf.transform(key.rawKey)
            db.transformCache = (key.rawKey, settings.kdf, transformed)
        }

        let masterSeed = SecureRandom.bytes(32)
        let iv = SecureRandom.bytes(settings.cipher.ivLength)
        let innerKey = SecureRandom.bytes(64)

        // Outer header
        var h = ByteWriter()
        h.u32(signature1); h.u32(signature2); h.u32(version)
        func field(_ id: HeaderField, _ value: Data) {
            h.u8(id.rawValue); h.u32(UInt32(value.count)); h.append(value)
        }
        field(.cipherID, settings.cipher.uuid.data)
        field(.compressionFlags, Data.le(UInt32(settings.compression ? 1 : 0)))
        field(.masterSeed, masterSeed)
        field(.encryptionIV, iv)
        field(.kdfParameters, settings.kdf.dictionary.serialized())
        if let pcd = db.publicCustomData { field(.publicCustomData, pcd) }
        field(.end, Data([0x0D, 0x0A, 0x0D, 0x0A]))
        let headerBytes = h.data

        let hmacBase = Hash.sha512(masterSeed, transformed, Data([1]))
        let masterKey = Hash.sha256(masterSeed, transformed)

        // Inner header + XML
        let pool = XMLMapping.BinaryPool()
        db.meta.generator = "SaveKey"
        let document = XMLMapping.buildDocument(db, pool: pool, v41: v41)
        var inner = ByteWriter()
        func innerField(_ id: InnerHeaderField, _ value: Data) {
            inner.u8(id.rawValue); inner.i32(Int32(value.count)); inner.append(value)
        }
        innerField(.innerRandomStreamID, Data.le(UInt32(3)))
        innerField(.innerRandomStreamKey, innerKey)
        for b in pool.items {
            var v = Data([b.isProtected ? 1 : 0])
            v.append(b.data)
            innerField(.binary, v)
        }
        innerField(.end, Data())
        let stream = try makeInnerStream(id: 3, key: innerKey)
        var plain = inner.data
        plain.append(XMLTree.serialize(document, protectedStream: stream))

        let compressed = settings.compression ? try Gzip.compress(plain) : plain
        let encrypted = try settings.cipher.encrypt(key: masterKey, iv: iv, compressed)

        var out = ByteWriter()
        out.append(headerBytes)
        out.append(Hash.sha256(headerBytes))
        out.append(Hash.hmacSHA256(key: blockHMACKey(UInt64.max, base: hmacBase), data: headerBytes))

        let blockSize = 1024 * 1024
        var index: UInt64 = 0
        var offset = encrypted.startIndex
        while true {
            let end = min(offset + blockSize, encrypted.endIndex)
            let block = encrypted.subdata(in: offset..<end)
            var msg = Data.le(index)
            msg.append(Data.le(Int32(block.count)))
            msg.append(block)
            out.append(Hash.hmacSHA256(key: blockHMACKey(index, base: hmacBase), data: msg))
            out.i32(Int32(block.count))
            out.append(block)
            if block.isEmpty { break }
            offset = end
            index += 1
        }

        db.settings.formatVersion = version
        return out.data
    }
}
