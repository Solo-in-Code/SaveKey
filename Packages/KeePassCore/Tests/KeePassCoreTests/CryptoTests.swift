// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import KeePassCore

final class CryptoTests: XCTestCase {
    func hex(_ s: String) -> Data { Data(hex: s)! }

    func testHashes() {
        let abc = Data("abc".utf8)
        XCTAssertEqual(Hash.sha256(abc).hexString, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hash.sha512(abc).hexString, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(Hash.sha1(abc).hexString, "a9993e364706816aba3e25717850c26c9cd0d89d")
        let long = Data(repeating: 0x61, count: 1000)
        XCTAssertEqual(Hash.sha256(long).hexString, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(Hash.hmacSHA256(key: Data("Jefe".utf8), data: Data("what do ya want for nothing?".utf8)).hexString,
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(Blake2b.hash([UInt8](abc), outputLength: 64).map { String(format: "%02x", $0) }.joined(),
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    }

    func testAES() throws {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let ecb = try AESCipher.ecbEncryptRounds(key: key, data: hex("00112233445566778899aabbccddeeff"), rounds: 1)
        XCTAssertEqual(ecb.hexString, "8ea2b7ca516745bfeafc49904b496089")
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let msg = Data("The quick brown fox jumps over the lazy dog, again and again!".utf8)
        let ct = try AESCipher.cbcEncrypt(key: key, iv: iv, plaintext: msg)
        XCTAssertEqual(ct.count % 16, 0)
        XCTAssertEqual(try AESCipher.cbcDecrypt(key: key, iv: iv, ciphertext: ct), msg)
    }

    func testChaCha20() throws {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = hex("000000000000004a00000000")
        let pt = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let c = try ChaCha20(key: key, nonce: nonce, counter: 1)
        let ct = c.xor(pt)
        XCTAssertEqual(ct.prefix(16).hexString, "6e2e359a2568f98041ba0728dd0d6981")
        XCTAssertEqual(ct.suffix(2).hexString, "874d")
    }

    func testSalsa20() throws {
        var key = Data(repeating: 0, count: 32); key[0] = 0x80
        let s = try Salsa20(key: key, nonce: Data(repeating: 0, count: 8))
        let ks = s.xor(Data(repeating: 0, count: 64))
        XCTAssertEqual(ks.hexString.uppercased(),
                       "E3BE8FDD8BECA2E3EA8EF9475B29A6E7003951E1097A5C38D23B7A5FAD9F6844B22C97559E2723C7CBBD3FE4FC8D9A0744652A83E72A9C461876AF4D7EF1A117")
    }

    func testArgon2RFC9106() throws {
        let pwd = Data(repeating: 1, count: 32), salt = Data(repeating: 2, count: 16)
        let secret = Data(repeating: 3, count: 8), ad = Data(repeating: 4, count: 12)
        let expected: [(Argon2.Variant, String)] = [
            (.d, "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb"),
            (.i, "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8"),
            (.id, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"),
        ]
        for (variant, tag) in expected {
            let out = try Argon2.hash(password: pwd, salt: salt, secret: secret, associatedData: ad,
                                      iterations: 3, memoryKiB: 32, parallelism: 4, variant: variant)
            XCTAssertEqual(out.hexString, tag, "Argon2\(variant)")
        }
    }

    func testArgon2Performance() throws {
        let start = Date()
        _ = try Argon2.hash(password: Data(repeating: 1, count: 32), salt: Data(repeating: 2, count: 32),
                            iterations: 2, memoryKiB: 64 * 1024, parallelism: 2, variant: .d)
        print("Argon2d 64 MiB, 2 iterations, 2 lanes: \(Date().timeIntervalSince(start))s")
    }

    func testGzipRoundTrip() throws {
        let text = Data(String(repeating: "KeePass gzip round trip. ", count: 5000).utf8)
        let z = try Gzip.compress(text)
        XCTAssertLessThan(z.count, text.count / 10)
        XCTAssertEqual(z.prefix(2), Data([0x1f, 0x8b]))
        XCTAssertEqual(try Gzip.decompress(z), text)
    }
}
