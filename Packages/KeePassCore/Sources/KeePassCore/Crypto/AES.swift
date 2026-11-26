// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// AES-256 in CBC mode (database payload) and repeated ECB (legacy AES-KDF).
/// CommonCrypto (hardware accelerated) on Apple platforms; portable code elsewhere.
public enum AESCipher {
    public static func cbcEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw KDBXError.invalidKeyOrIV }
        #if canImport(CommonCrypto)
        return try commonCryptoCBC(op: CCOperation(kCCEncrypt), key: key, iv: iv, input: plaintext)
        #else
        let aes = SoftAES(key: [UInt8](key))
        let padLen = 16 - plaintext.count % 16
        var data = [UInt8](plaintext) + [UInt8](repeating: UInt8(padLen), count: padLen)
        var prev = [UInt8](iv)
        for off in stride(from: 0, to: data.count, by: 16) {
            var block = [UInt8](data[off..<off + 16])
            for i in 0..<16 { block[i] ^= prev[i] }
            prev = aes.encrypt(block)
            data.replaceSubrange(off..<off + 16, with: prev)
        }
        return Data(data)
        #endif
    }

    public static func cbcDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw KDBXError.invalidKeyOrIV }
        guard ciphertext.count % 16 == 0, !ciphertext.isEmpty else { throw KDBXError.invalidCredentials }
        #if canImport(CommonCrypto)
        do {
            return try commonCryptoCBC(op: CCOperation(kCCDecrypt), key: key, iv: iv, input: ciphertext)
        } catch {
            // A padding failure almost always means the key was wrong.
            throw KDBXError.invalidCredentials
        }
        #else
        let aes = SoftAES(key: [UInt8](key))
        let input = [UInt8](ciphertext)
        var out = [UInt8](repeating: 0, count: input.count)
        var prev = [UInt8](iv)
        for off in stride(from: 0, to: input.count, by: 16) {
            let block = [UInt8](input[off..<off + 16])
            let dec = aes.decrypt(block)
            for i in 0..<16 { out[off + i] = dec[i] ^ prev[i] }
            prev = block
        }
        guard let pad = out.last, pad >= 1, pad <= 16, out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw KDBXError.invalidCredentials
        }
        return Data(out.dropLast(Int(pad)))
        #endif
    }

    /// Encrypts `data` (a multiple of 16 bytes) `rounds` times with AES-256-ECB.
    public static func ecbEncryptRounds(key: Data, data: Data, rounds: UInt64) throws -> Data {
        guard key.count == 32, data.count % 16 == 0 else { throw KDBXError.invalidKeyOrIV }
        #if canImport(CommonCrypto)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { kp in
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            kp.baseAddress, kCCKeySizeAES256, nil, &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { throw KDBXError.cryptoFailure("CCCryptorCreate \(status)") }
        defer { CCCryptorRelease(cryptor) }
        var buffer = [UInt8](data)
        var out = [UInt8](repeating: 0, count: buffer.count)
        var moved = 0
        var r: UInt64 = 0
        while r < rounds {
            let st = CCCryptorUpdate(cryptor, buffer, buffer.count, &out, out.count, &moved)
            guard st == kCCSuccess else { throw KDBXError.cryptoFailure("CCCryptorUpdate \(st)") }
            swap(&buffer, &out)
            r += 1
        }
        return Data(buffer)
        #else
        let aes = SoftAES(key: [UInt8](key))
        var buffer = [UInt8](data)
        for _ in 0..<rounds {
            for off in stride(from: 0, to: buffer.count, by: 16) {
                let enc = aes.encrypt([UInt8](buffer[off..<off + 16]))
                buffer.replaceSubrange(off..<off + 16, with: enc)
            }
        }
        return Data(buffer)
        #endif
    }

    #if canImport(CommonCrypto)
    private static func commonCryptoCBC(op: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { op_ in
            input.withUnsafeBytes { ip in
                key.withUnsafeBytes { kp in
                    iv.withUnsafeBytes { vp in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kp.baseAddress, key.count, vp.baseAddress,
                                ip.baseAddress, input.count, op_.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw KDBXError.cryptoFailure("CCCrypt \(status)") }
        out.count = moved
        return out
    }
    #endif
}

// MARK: - Portable AES-256 (used for tests on non-Apple platforms)

struct SoftAES {
    private static let sbox: [UInt8] = {
        var s = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            let carry: UInt8 = (p & 0x80) != 0 ? 0x1B : 0
            p = p ^ (p << 1) ^ carry
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if (q & 0x80) != 0 { q ^= 0x09 }
            var x: UInt8 = q ^ rotl8(q, 1)
            x ^= rotl8(q, 2)
            x ^= rotl8(q, 3)
            x ^= rotl8(q, 4)
            s[Int(p)] = x ^ 0x63
        } while p != 1
        s[0] = 0x63
        return s
    }()
    private static let invSbox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()
    private static func rotl8(_ x: UInt8, _ s: UInt8) -> UInt8 { (x << s) | (x >> (8 - s)) }
    private static func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0) }
    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, r: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { r ^= a }
            a = xtime(a); b >>= 1
        }
        return r
    }

    private let roundKeys: [[UInt8]] // 15 round keys of 16 bytes

    init(key: [UInt8]) {
        precondition(key.count == 32)
        var w = [[UInt8]]()
        for i in 0..<8 { w.append(Array(key[i * 4..<i * 4 + 4])) }
        var rcon: UInt8 = 1
        for i in 8..<60 {
            var t = w[i - 1]
            if i % 8 == 0 {
                t = [t[1], t[2], t[3], t[0]].map { SoftAES.sbox[Int($0)] }
                t[0] ^= rcon
                rcon = SoftAES.xtime(rcon)
            } else if i % 8 == 4 {
                t = t.map { SoftAES.sbox[Int($0)] }
            }
            w.append(zip(w[i - 8], t).map { $0 ^ $1 })
        }
        var keys = [[UInt8]]()
        for r in 0..<15 {
            var rk = [UInt8]()
            for j in 0..<4 { rk.append(contentsOf: w[r * 4 + j]) }
            keys.append(rk)
        }
        roundKeys = keys
    }

    func encrypt(_ input: [UInt8]) -> [UInt8] {
        var s = zip(input, roundKeys[0]).map { $0 ^ $1 }
        for round in 1...14 {
            s = s.map { SoftAES.sbox[Int($0)] }
            s = shiftRows(s)
            if round != 14 { s = mixColumns(s) }
            s = zip(s, roundKeys[round]).map { $0 ^ $1 }
        }
        return s
    }

    func decrypt(_ input: [UInt8]) -> [UInt8] {
        var s = zip(input, roundKeys[14]).map { $0 ^ $1 }
        for round in stride(from: 13, through: 0, by: -1) {
            s = invShiftRows(s)
            s = s.map { SoftAES.invSbox[Int($0)] }
            s = zip(s, roundKeys[round]).map { $0 ^ $1 }
            if round != 0 { s = invMixColumns(s) }
        }
        return s
    }

    private func shiftRows(_ s: [UInt8]) -> [UInt8] {
        var o = s
        for c in 0..<4 { for r in 0..<4 { o[c * 4 + r] = s[((c + r) % 4) * 4 + r] } }
        return o
    }
    private func invShiftRows(_ s: [UInt8]) -> [UInt8] {
        var o = s
        for c in 0..<4 { for r in 0..<4 { o[((c + r) % 4) * 4 + r] = s[c * 4 + r] } }
        return o
    }
    private func mixColumns(_ s: [UInt8]) -> [UInt8] {
        var o = s
        for c in 0..<4 {
            let a = Array(s[c * 4..<c * 4 + 4])
            o[c * 4 + 0] = SoftAES.mul(a[0], 2) ^ SoftAES.mul(a[1], 3) ^ a[2] ^ a[3]
            o[c * 4 + 1] = a[0] ^ SoftAES.mul(a[1], 2) ^ SoftAES.mul(a[2], 3) ^ a[3]
            o[c * 4 + 2] = a[0] ^ a[1] ^ SoftAES.mul(a[2], 2) ^ SoftAES.mul(a[3], 3)
            o[c * 4 + 3] = SoftAES.mul(a[0], 3) ^ a[1] ^ a[2] ^ SoftAES.mul(a[3], 2)
        }
        return o
    }
    private func invMixColumns(_ s: [UInt8]) -> [UInt8] {
        var o = s
        for c in 0..<4 {
            let a = Array(s[c * 4..<c * 4 + 4])
            o[c * 4 + 0] = SoftAES.mul(a[0], 14) ^ SoftAES.mul(a[1], 11) ^ SoftAES.mul(a[2], 13) ^ SoftAES.mul(a[3], 9)
            o[c * 4 + 1] = SoftAES.mul(a[0], 9) ^ SoftAES.mul(a[1], 14) ^ SoftAES.mul(a[2], 11) ^ SoftAES.mul(a[3], 13)
            o[c * 4 + 2] = SoftAES.mul(a[0], 13) ^ SoftAES.mul(a[1], 9) ^ SoftAES.mul(a[2], 14) ^ SoftAES.mul(a[3], 11)
            o[c * 4 + 3] = SoftAES.mul(a[0], 11) ^ SoftAES.mul(a[1], 13) ^ SoftAES.mul(a[2], 9) ^ SoftAES.mul(a[3], 14)
        }
        return o
    }
}
