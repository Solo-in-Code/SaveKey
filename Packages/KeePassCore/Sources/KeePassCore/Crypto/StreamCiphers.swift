// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A keystream generator that can XOR an arbitrary number of byte runs
/// continuing from where the previous run stopped.
public protocol KeystreamCipher: AnyObject {
    func xor(_ data: inout [UInt8])
}

public extension KeystreamCipher {
    func xor(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        xor(&bytes)
        return Data(bytes)
    }
}

@inline(__always) private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

@inline(__always) private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

/// ChaCha20 as specified by RFC 7539 (32-bit block counter, 96-bit nonce).
public final class ChaCha20: KeystreamCipher {
    private var state = [UInt32](repeating: 0, count: 16)
    private var block = [UInt8](repeating: 0, count: 64)
    private var position = 64

    public init(key: Data, nonce: Data, counter: UInt32 = 0) throws {
        guard key.count == 32, nonce.count == 12 else { throw KDBXError.invalidKeyOrIV }
        let k = [UInt8](key), n = [UInt8](nonce)
        state[0] = 0x61707865; state[1] = 0x3320646e; state[2] = 0x79622d32; state[3] = 0x6b206574
        for i in 0..<8 { state[4 + i] = le32(k, i * 4) }
        state[12] = counter
        for i in 0..<3 { state[13 + i] = le32(n, i * 4) }
    }

    private func nextBlock() {
        var x = state
        @inline(__always) func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[a] = x[a] &+ x[b]; x[d] = rotl(x[d] ^ x[a], 16)
            x[c] = x[c] &+ x[d]; x[b] = rotl(x[b] ^ x[c], 12)
            x[a] = x[a] &+ x[b]; x[d] = rotl(x[d] ^ x[a], 8)
            x[c] = x[c] &+ x[d]; x[b] = rotl(x[b] ^ x[c], 7)
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
            qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
        }
        for i in 0..<16 {
            let v = x[i] &+ state[i]
            block[i * 4] = UInt8(truncatingIfNeeded: v)
            block[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            block[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            block[i * 4 + 3] = UInt8(truncatingIfNeeded: v >> 24)
        }
        state[12] = state[12] &+ 1
        position = 0
    }

    public func xor(_ data: inout [UInt8]) {
        data.withUnsafeMutableBufferPointer { buf in
            for i in 0..<buf.count {
                if position == 64 { nextBlock() }
                buf[i] ^= block[position]
                position += 1
            }
        }
    }
}

/// Salsa20/20 with a 64-bit nonce (used by KDBX 3.1 for protected values).
public final class Salsa20: KeystreamCipher {
    private var state = [UInt32](repeating: 0, count: 16)
    private var block = [UInt8](repeating: 0, count: 64)
    private var position = 64

    public init(key: Data, nonce: Data) throws {
        guard key.count == 32, nonce.count == 8 else { throw KDBXError.invalidKeyOrIV }
        let k = [UInt8](key), n = [UInt8](nonce)
        state[0] = 0x61707865; state[5] = 0x3320646e; state[10] = 0x79622d32; state[15] = 0x6b206574
        for i in 0..<4 { state[1 + i] = le32(k, i * 4) }
        for i in 0..<4 { state[11 + i] = le32(k, 16 + i * 4) }
        state[6] = le32(n, 0); state[7] = le32(n, 4)
        state[8] = 0; state[9] = 0
    }

    private func nextBlock() {
        var x = state
        @inline(__always) func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[b] ^= rotl(x[a] &+ x[d], 7)
            x[c] ^= rotl(x[b] &+ x[a], 9)
            x[d] ^= rotl(x[c] &+ x[b], 13)
            x[a] ^= rotl(x[d] &+ x[c], 18)
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(5, 9, 13, 1); qr(10, 14, 2, 6); qr(15, 3, 7, 11)
            qr(0, 1, 2, 3); qr(5, 6, 7, 4); qr(10, 11, 8, 9); qr(15, 12, 13, 14)
        }
        for i in 0..<16 {
            let v = x[i] &+ state[i]
            block[i * 4] = UInt8(truncatingIfNeeded: v)
            block[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            block[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            block[i * 4 + 3] = UInt8(truncatingIfNeeded: v >> 24)
        }
        state[8] = state[8] &+ 1
        if state[8] == 0 { state[9] = state[9] &+ 1 }
        position = 0
    }

    public func xor(_ data: inout [UInt8]) {
        data.withUnsafeMutableBufferPointer { buf in
            for i in 0..<buf.count {
                if position == 64 { nextBlock() }
                buf[i] ^= block[position]
                position += 1
            }
        }
    }
}
