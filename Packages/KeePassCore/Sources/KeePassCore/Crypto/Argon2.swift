// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Argon2 (RFC 9106), version 0x13 and 0x10, variants d / i / id.
/// Lanes of each slice are processed concurrently.
public enum Argon2 {
    public enum Variant: UInt32 {
        case d = 0, i = 1, id = 2
    }

    public static func hash(password: Data, salt: Data, secret: Data = Data(), associatedData: Data = Data(),
                            iterations: UInt32, memoryKiB: UInt32, parallelism: UInt32,
                            outputLength: Int = 32, variant: Variant, version: UInt32 = 0x13) throws -> Data {
        guard parallelism >= 1, parallelism <= 0xFFFFFF, iterations >= 1, salt.count >= 8,
              memoryKiB >= 8 * parallelism, outputLength >= 4 else {
            throw KDBXError.invalidKDFParameters
        }
        guard version == 0x13 || version == 0x10 else { throw KDBXError.invalidKDFParameters }

        // H0
        var b = Blake2b(outputLength: 64)
        b.update(parallelism)
        b.update(UInt32(outputLength))
        b.update(memoryKiB)
        b.update(iterations)
        b.update(version)
        b.update(variant.rawValue)
        b.update(UInt32(password.count)); b.update([UInt8](password))
        b.update(UInt32(salt.count)); b.update([UInt8](salt))
        b.update(UInt32(secret.count)); b.update([UInt8](secret))
        b.update(UInt32(associatedData.count)); b.update([UInt8](associatedData))
        let h0 = b.finalize()

        let lanes = Int(parallelism)
        let segmentLength = Int(memoryKiB) / (lanes * 4)
        let laneLength = segmentLength * 4
        let blockCount = laneLength * lanes

        let memory = UnsafeMutablePointer<UInt64>.allocate(capacity: blockCount * 128)
        memory.initialize(repeating: 0, count: blockCount * 128)
        defer {
            memory.update(repeating: 0, count: blockCount * 128)
            memory.deallocate()
        }

        // First two blocks of every lane.
        for lane in 0..<lanes {
            for j in 0..<2 {
                var input = h0
                input += le32(UInt32(j)) + le32(UInt32(lane))
                let block = hPrime(input, length: 1024)
                let dst = memory + (lane * laneLength + j) * 128
                for w in 0..<128 { dst[w] = readLE64(block, w * 8) }
            }
        }

        let ctx = Context(memory: memory, lanes: lanes, laneLength: laneLength, segmentLength: segmentLength,
                          blockCount: blockCount, passes: Int(iterations), variant: variant, version: version)
        for pass in 0..<Int(iterations) {
            for slice in 0..<4 {
                if lanes == 1 {
                    ctx.fillSegment(pass: pass, lane: 0, slice: slice)
                } else {
                    DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                        ctx.fillSegment(pass: pass, lane: lane, slice: slice)
                    }
                }
            }
        }

        // Final block = XOR of last block of each lane.
        var final = [UInt64](repeating: 0, count: 128)
        for lane in 0..<lanes {
            let src = memory + (lane * laneLength + laneLength - 1) * 128
            for w in 0..<128 { final[w] ^= src[w] }
        }
        var finalBytes = [UInt8]()
        finalBytes.reserveCapacity(1024)
        for w in final { finalBytes += le64(w) }
        return Data(hPrime(finalBytes, length: outputLength))
    }

    // MARK: - Helpers

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
    }
    private static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (UInt64($0) * 8)) & 0xff) } }
    private static func readLE64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(b[o + i]) }
        return v
    }

    /// Variable-length hash H' from the spec.
    static func hPrime(_ input: [UInt8], length: Int) -> [UInt8] {
        if length <= 64 {
            var b = Blake2b(outputLength: length)
            b.update(UInt32(length))
            b.update(input)
            return b.finalize()
        }
        var b = Blake2b(outputLength: 64)
        b.update(UInt32(length))
        b.update(input)
        var v = b.finalize()
        var out = Array(v.prefix(32))
        let r = (length + 31) / 32 - 2
        if r >= 2 {
            for _ in 2...r {
                v = Blake2b.hash(v, outputLength: 64)
                out += v.prefix(32)
            }
        }
        out += Blake2b.hash(v, outputLength: length - 32 * r)
        return out
    }

    private final class Context: @unchecked Sendable {
        let memory: UnsafeMutablePointer<UInt64>
        let lanes: Int, laneLength: Int, segmentLength: Int, blockCount: Int, passes: Int
        let variant: Variant, version: UInt32

        init(memory: UnsafeMutablePointer<UInt64>, lanes: Int, laneLength: Int, segmentLength: Int,
             blockCount: Int, passes: Int, variant: Variant, version: UInt32) {
            self.memory = memory; self.lanes = lanes; self.laneLength = laneLength
            self.segmentLength = segmentLength; self.blockCount = blockCount; self.passes = passes
            self.variant = variant; self.version = version
        }

        func fillSegment(pass: Int, lane: Int, slice: Int) {
            let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: 128 * 5)
            scratch.initialize(repeating: 0, count: 128 * 5)
            defer { scratch.deallocate() }
            let zeroBlock = scratch
            let inputBlock = scratch + 128
            let addressBlock = scratch + 256
            let tmpR = scratch + 384
            let tmpT = scratch + 512

            let dataIndependent = variant == .i || (variant == .id && pass == 0 && slice < 2)
            if dataIndependent {
                inputBlock[0] = UInt64(pass)
                inputBlock[1] = UInt64(lane)
                inputBlock[2] = UInt64(slice)
                inputBlock[3] = UInt64(blockCount)
                inputBlock[4] = UInt64(passes)
                inputBlock[5] = UInt64(variant.rawValue)
            }

            func nextAddresses() {
                inputBlock[6] &+= 1
                Argon2.fillBlock(prev: zeroBlock, ref: inputBlock, next: addressBlock, withXor: false, r: tmpR, t: tmpT)
                Argon2.fillBlock(prev: zeroBlock, ref: addressBlock, next: addressBlock, withXor: false, r: tmpR, t: tmpT)
            }

            var startingIndex = 0
            if pass == 0 && slice == 0 {
                startingIndex = 2
                if dataIndependent { nextAddresses() }
            }

            var currOffset = lane * laneLength + slice * segmentLength + startingIndex
            var prevOffset = (currOffset % laneLength == 0) ? currOffset + laneLength - 1 : currOffset - 1

            var i = startingIndex
            while i < segmentLength {
                if currOffset % laneLength == 1 { prevOffset = currOffset - 1 }
                let pseudoRand: UInt64
                if dataIndependent {
                    if i % 128 == 0 { nextAddresses() }
                    pseudoRand = addressBlock[i % 128]
                } else {
                    pseudoRand = memory[prevOffset * 128]
                }
                var refLane = Int((pseudoRand >> 32) % UInt64(lanes))
                if pass == 0 && slice == 0 { refLane = lane }
                let refIndex = indexAlpha(pass: pass, slice: slice, index: i,
                                          pseudoRand: pseudoRand & 0xFFFFFFFF, sameLane: refLane == lane)
                let refBlock = memory + (laneLength * refLane + refIndex) * 128
                let currBlock = memory + currOffset * 128
                let prevBlock = memory + prevOffset * 128
                let withXor = version != 0x10 && pass != 0
                Argon2.fillBlock(prev: prevBlock, ref: refBlock, next: currBlock, withXor: withXor, r: tmpR, t: tmpT)
                i += 1; currOffset += 1; prevOffset += 1
            }
        }

        private func indexAlpha(pass: Int, slice: Int, index: Int, pseudoRand: UInt64, sameLane: Bool) -> Int {
            var areaSize: Int
            if pass == 0 {
                if slice == 0 {
                    areaSize = index - 1
                } else if sameLane {
                    areaSize = slice * segmentLength + index - 1
                } else {
                    areaSize = slice * segmentLength + (index == 0 ? -1 : 0)
                }
            } else {
                if sameLane {
                    areaSize = laneLength - segmentLength + index - 1
                } else {
                    areaSize = laneLength - segmentLength + (index == 0 ? -1 : 0)
                }
            }
            var rel = pseudoRand
            rel = (rel &* rel) >> 32
            rel = UInt64(areaSize) &- 1 &- ((UInt64(areaSize) &* rel) >> 32)
            var start = 0
            if pass != 0 { start = slice == 3 ? 0 : (slice + 1) * segmentLength }
            return Int((UInt64(start) &+ rel) % UInt64(laneLength))
        }
    }

    // MARK: - Compression function G

    @inline(__always) private static func fBlaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        let m: UInt64 = 0xFFFFFFFF
        return x &+ y &+ 2 &* ((x & m) &* (y & m))
    }

    @inline(__always) private static func gb(_ a: inout UInt64, _ b: inout UInt64, _ c: inout UInt64, _ d: inout UInt64) {
        a = fBlaMka(a, b); d = (d ^ a).rotr(32)
        c = fBlaMka(c, d); b = (b ^ c).rotr(24)
        a = fBlaMka(a, b); d = (d ^ a).rotr(16)
        c = fBlaMka(c, d); b = (b ^ c).rotr(63)
    }

    @inline(__always) private static func permute(_ p: UnsafeMutablePointer<UInt64>, _ idx: (Int) -> Int) {
        var v0 = p[idx(0)], v1 = p[idx(1)], v2 = p[idx(2)], v3 = p[idx(3)]
        var v4 = p[idx(4)], v5 = p[idx(5)], v6 = p[idx(6)], v7 = p[idx(7)]
        var v8 = p[idx(8)], v9 = p[idx(9)], v10 = p[idx(10)], v11 = p[idx(11)]
        var v12 = p[idx(12)], v13 = p[idx(13)], v14 = p[idx(14)], v15 = p[idx(15)]
        gb(&v0, &v4, &v8, &v12); gb(&v1, &v5, &v9, &v13)
        gb(&v2, &v6, &v10, &v14); gb(&v3, &v7, &v11, &v15)
        gb(&v0, &v5, &v10, &v15); gb(&v1, &v6, &v11, &v12)
        gb(&v2, &v7, &v8, &v13); gb(&v3, &v4, &v9, &v14)
        p[idx(0)] = v0; p[idx(1)] = v1; p[idx(2)] = v2; p[idx(3)] = v3
        p[idx(4)] = v4; p[idx(5)] = v5; p[idx(6)] = v6; p[idx(7)] = v7
        p[idx(8)] = v8; p[idx(9)] = v9; p[idx(10)] = v10; p[idx(11)] = v11
        p[idx(12)] = v12; p[idx(13)] = v13; p[idx(14)] = v14; p[idx(15)] = v15
    }

    private static func fillBlock(prev: UnsafeMutablePointer<UInt64>, ref: UnsafeMutablePointer<UInt64>,
                                  next: UnsafeMutablePointer<UInt64>, withXor: Bool,
                                  r: UnsafeMutablePointer<UInt64>, t: UnsafeMutablePointer<UInt64>) {
        for w in 0..<128 { r[w] = ref[w] ^ prev[w] }
        if withXor {
            for w in 0..<128 { t[w] = r[w] ^ next[w] }
        } else {
            for w in 0..<128 { t[w] = r[w] }
        }
        for row in 0..<8 {
            let base = row * 16
            permute(r) { base + $0 }
        }
        for col in 0..<8 {
            let base = col * 2
            permute(r) { base + ($0 >> 1) * 16 + ($0 & 1) }
        }
        for w in 0..<128 { next[w] = t[w] ^ r[w] }
    }
}
