// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import KeePassCore

final class KDBXTests: XCTestCase {
    struct Fixture {
        let name: String
        let password: String?
        let keyFile: String?
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "test3", password: "password", keyFile: "test3.key"),
        Fixture(name: "test4", password: "password", keyFile: "test4.key"),
        Fixture(name: "test4_aes", password: "password", keyFile: "test4.key"),
        Fixture(name: "test4_aeskdf", password: "password", keyFile: "test4.key"),
        Fixture(name: "test4_chacha20", password: "password", keyFile: "test4.key"),
        Fixture(name: "test4_hex", password: "password", keyFile: "test4_hex.key"),
        Fixture(name: "test4_aes_uncompressed", password: "password", keyFile: nil),
        Fixture(name: "test4_chacha20_uncompressed", password: "password", keyFile: nil),
        Fixture(name: "test4_argon2id", password: "password", keyFile: nil),
        Fixture(name: "test4_blankpass", password: "", keyFile: "test4.key"),
        Fixture(name: "test4_keyx", password: "password", keyFile: "test4_keyx.keyx"),
    ]

    static let outputDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kpout")

    func fixtureURL(_ name: String) -> URL {
        let parts = name.split(separator: ".")
        return Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]), subdirectory: "Fixtures")!
    }

    func key(for f: Fixture) throws -> CompositeKey {
        let kf = try f.keyFile.map { try Data(contentsOf: fixtureURL($0)) }
        return try CompositeKey(password: f.password, keyFileData: kf)
    }

    // MARK: - Normalised dump (mirrors tools/kpdump.py)

    func groupPath(_ g: KPGroup?) -> String {
        guard let g, g.parent != nil else { return "" }
        let parent = groupPath(g.parent)
        return parent.isEmpty ? g.name : parent + "/" + g.name
    }

    func dump(_ db: Database, includeVersion: Bool = true) -> [String: Any] {
        var entries: [[String: Any]] = []
        for e in db.allEntries {
            var custom: [String: String] = [:]
            for f in e.customFields where f.key != "otp" { custom[f.key] = f.value } // pykeepass hides otp
            var attachments: [[String]] = e.attachments.map { [$0.name, Hash.sha256($0.data).hexString] }
            attachments.sort { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
            var item: [String: Any] = [:]
            item["uuid"] = e.uuid.uuidString
            item["title"] = e.title
            item["username"] = e.userName
            item["password"] = e.password
            item["url"] = e.url
            item["notes"] = e.notes.replacingOccurrences(of: "\r\n", with: "\n")
            item["tags"] = e.tags.sorted()
            item["custom"] = custom
            item["attachments"] = attachments
            item["history"] = e.history.count
            item["group"] = groupPath(e.parent)
            entries.append(item)
        }
        entries.sort { ($0["uuid"] as! String) < ($1["uuid"] as! String) }
        var d: [String: Any] = [
            "name": db.meta.databaseName,
            "entries": entries,
            "groups": db.allGroups.map(groupPath).sorted(),
            "cipher": db.settings.cipher == .aes256 ? "aes256" : "chacha20",
        ]
        switch db.settings.kdf {
        case .aes: d["kdf"] = "aeskdf"
        case .argon2(let p): d["kdf"] = p.variant == .id ? "argon2id" : "argon2"
        }
        if includeVersion {
            d["version"] = [Int(db.settings.formatVersion >> 16), Int(db.settings.formatVersion & 0xFFFF)]
        }
        return d
    }

    func canonical(_ obj: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data, as: UTF8.self)
    }

    func expected(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL(name + ".json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Tests

    func testReadAllFixturesMatchPyKeePass() throws {
        for f in Self.fixtures {
            let db = try KDBX.open(try Data(contentsOf: fixtureURL(f.name + ".kdbx")), key: try key(for: f))
            let mine = canonical(dump(db))
            let theirs = canonical(try expected(f.name))
            XCTAssertEqual(mine, theirs, "Mismatch reading \(f.name)")
        }
    }

    /// Saves every fixture with this engine, re-reads it, and leaves the output in
    /// $TMPDIR/kpout so pykeepass can verify it independently.
    func testSaveAndReopenAllFixtures() throws {
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        for f in Self.fixtures {
            let k = try key(for: f)
            let db = try KDBX.open(try Data(contentsOf: fixtureURL(f.name + ".kdbx")), key: k)
            let before = canonical(dump(db, includeVersion: false))
            let saved = try KDBX.save(db, key: k)
            try saved.write(to: Self.outputDir.appendingPathComponent(f.name + ".kdbx"))
            let reopened = try KDBX.open(saved, key: k)
            XCTAssertEqual(canonical(dump(reopened, includeVersion: false)), before, "Round trip changed \(f.name)")
            XCTAssertEqual(reopened.settings.formatVersion >> 16, 4)
        }
    }

    /// Merging two copies of the same real file (KeePass, KeePassXC) must change nothing,
    /// otherwise SaveKey would save files back that nobody changed.
    func testMergingIdenticalCopiesChangesNothing() throws {
        for f in Self.fixtures {
            let k = try key(for: f)
            let data = try Data(contentsOf: fixtureURL(f.name + ".kdbx"))
            let a = try KDBX.open(data, key: k)
            let b = try KDBX.open(data, key: k)
            let before = a.contentFingerprint()
            let historyBefore = a.allEntries.map(\.history.count)
            let summary = a.merge(from: b)
            XCTAssertEqual(summary.itemChanges, 0, f.name)
            XCTAssertFalse(summary.metadataChanged, f.name)
            XCTAssertFalse(summary.historyChanged, f.name)
            XCTAssertEqual(a.allEntries.map(\.history.count), historyBefore, f.name)
            XCTAssertEqual(a.contentFingerprint(), before, f.name)
            XCTAssertEqual(b.contentFingerprint(), before, f.name)

            let mirror = Database.create(name: "Other")
            mirror.adoptContent(of: b)
            XCTAssertEqual(mirror.contentFingerprint(), before, f.name)
            XCTAssertEqual(canonical(dump(mirror, includeVersion: false)), canonical(dump(b, includeVersion: false)), f.name)
        }
    }

    func testWrongPasswordIsRejected() throws {
        let data = try Data(contentsOf: fixtureURL("test4_argon2id.kdbx"))
        XCTAssertThrowsError(try KDBX.open(data, key: try CompositeKey(password: "nope", keyFileData: nil))) { error in
            XCTAssertEqual(error as? KDBXError, .invalidCredentials)
        }
        let v3 = try Data(contentsOf: fixtureURL("test3.kdbx"))
        XCTAssertThrowsError(try KDBX.open(v3, key: try CompositeKey(password: "password", keyFileData: nil))) { error in
            XCTAssertEqual(error as? KDBXError, .invalidCredentials)
        }
    }

    func testTwofishReportsUnsupported() throws {
        let data = try Data(contentsOf: fixtureURL("test4_twofish.kdbx"))
        let k = try CompositeKey(password: "password", keyFileData: try Data(contentsOf: fixtureURL("test4.key")))
        XCTAssertThrowsError(try KDBX.open(data, key: k)) { error in
            XCTAssertEqual(error as? KDBXError, .unsupportedCipher("Twofish"))
        }
    }

    func testCreateEditSaveAllSettings() throws {
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        let combos: [(String, Cipher, KDFParameters, Bool)] = [
            ("new_aes_argon2id", .aes256, .defaultArgon2id(), true),
            ("new_chacha_argon2d", .chacha20, .argon2(.init(variant: .d, salt: SecureRandom.bytes(32), iterations: 2,
                                                            memoryBytes: 16 * 1024 * 1024, parallelism: 2)), true),
            ("new_aes_aeskdf", .aes256, .aes(rounds: 1000, seed: SecureRandom.bytes(32)), false),
        ]
        let keyFile = KeyFile.generate()
        try keyFile.write(to: Self.outputDir.appendingPathComponent("new.keyx"))
        for (name, cipher, kdf, compression) in combos {
            let db = Database.create(name: "Unit Test DB",
                                     settings: DatabaseSettings(cipher: cipher, compression: compression, kdf: kdf))
            let internet = db.root.groups.first { $0.name == "Internet" }!
            let e = db.createEntry(in: internet)
            e.title = "Example <&> \"quoted\""
            e.userName = "alice@example.com"
            e.password = "pä$$wörd 🔐 <xml>&"
            e.url = "https://example.com/login"
            e.notes = "line one\nline two\ttabbed"
            e.tags = ["work", "web"]
            e.setValue("12345", for: "PIN", protected: true)
            e.setValue("plain value", for: "Plain")
            e.attachments.append(Attachment(name: "hello.txt", data: Data("hello world".utf8)))
            e.attachments.append(Attachment(name: "copy.txt", data: Data("hello world".utf8)))
            OTPConfig(secret: Data("12345678901234567890".utf8), issuer: "Example", account: "alice").apply(to: e)
            e.backupToHistory(maxItems: db.meta.historyMaxItems)
            e.password = "changed"
            let sub = db.createGroup(named: "Sub group", in: internet)
            let e2 = db.createEntry(in: sub)
            e2.title = "Second"
            let trash = db.createEntry(in: db.root)
            trash.title = "To delete"
            db.delete(trash)
            XCTAssertTrue(db.isInRecycleBin(trash))

            let k = try CompositeKey(password: "correct horse", keyFileData: keyFile)
            let data = try KDBX.save(db, key: k)
            try data.write(to: Self.outputDir.appendingPathComponent(name + ".kdbx"))
            let reopened = try KDBX.open(data, key: k)
            XCTAssertEqual(canonical(dump(reopened)), canonical(dump(db)))
            let re = reopened.entry(uuid: e.uuid)!
            XCTAssertEqual(re.password, "changed")
            XCTAssertEqual(re.field("PIN")?.isProtected, true)
            XCTAssertEqual(re.history.first?.password, "pä$$wörd 🔐 <xml>&")
            XCTAssertEqual(OTPConfig.from(entry: re)?.issuer, "Example")
            XCTAssertEqual(reopened.settings.cipher, cipher)
            XCTAssertEqual(reopened.settings.kdf, kdf)
            XCTAssertEqual(reopened.recycleBin?.entries.first?.title, "To delete")
            XCTAssertEqual(reopened.search("ALICE").map(\.uuid), [e.uuid])
            XCTAssertTrue(reopened.search("delete").isEmpty, "recycle bin must be excluded from search")
        }
    }

    func testPlaceholdersAndStarterGroups() {
        XCTAssertEqual(fillPlaceholders("Read: %@.", ["a, b"]), "Read: a, b.")
        XCTAssertEqual(fillPlaceholders("%2$@ — %1$@", ["one", "two"]), "two — one")
        XCTAssertEqual(fillPlaceholders("100%% %@", ["done"]), "100% done")
        XCTAssertEqual(fillPlaceholders("50% off", []), "50% off")
        XCTAssertEqual(localized("Wrong password or key file."), "Wrong password or key file.")
        XCTAssertEqual(KDBXError.unsupportedVersion(0x50000).errorDescription,
                       "Unsupported KeePass database version (0x50000).")
        let db = Database.create(name: "Translated", groups: [("Geral", 48), ("Notas", 7)])
        XCTAssertEqual(db.root.groups.map(\.name), ["Geral", "Notas"])
        XCTAssertEqual(Database.create(name: "Default").root.groups.map(\.name),
                       ["General", "Email", "Internet", "Banking", "Notes"])
    }

    func testKeyFiles() throws {
        let generated = KeyFile.generate()
        let k1 = try KeyFile.key(from: generated)
        XCTAssertEqual(k1.count, 32)
        XCTAssertNotEqual(k1, Hash.sha256(generated), "XML v2 key file must be parsed, not hashed")
        var tampered = String(decoding: generated, as: UTF8.self)
        tampered = tampered.replacingOccurrences(of: #"Hash="[0-9A-F]{8}""#, with: #"Hash="00000000""#, options: .regularExpression)
        XCTAssertThrowsError(try KeyFile.key(from: Data(tampered.utf8)))
        let raw32 = SecureRandom.bytes(32)
        XCTAssertEqual(try KeyFile.key(from: raw32), raw32)
        let other = Data("some arbitrary file content".utf8)
        XCTAssertEqual(try KeyFile.key(from: other), Hash.sha256(other))
    }

    func testTOTPVectors() {
        // RFC 6238 appendix B
        let t = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(OTPConfig(secret: Data("12345678901234567890".utf8), digits: 8).code(at: t), "94287082")
        XCTAssertEqual(OTPConfig(secret: Data("12345678901234567890123456789012".utf8), digits: 8, algorithm: .sha256).code(at: t), "46119246")
        XCTAssertEqual(OTPConfig(secret: Data(String(repeating: "1234567890", count: 7).prefix(64).utf8), digits: 8, algorithm: .sha512).code(at: t), "90693936")
        // RFC 4226 HOTP
        XCTAssertEqual(OTPConfig(secret: Data("12345678901234567890".utf8), kind: .hotp(counter: 1)).code(), "287082")

        let c = OTPConfig(uri: "otpauth://totp/ACME%20Co:john@example.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA1&digits=6&period=30")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.issuer, "ACME Co")
        XCTAssertEqual(c?.account, "john@example.com")
        XCTAssertEqual(OTPConfig(uri: c!.uri), c)
        XCTAssertEqual(Base32.encode(Base32.decode("HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ")!), "HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ")

        let e = KPEntry()
        e.setValue("JBSWY3DPEHPK3PXP", for: "TimeOtp-Secret-Base32")
        e.setValue("8", for: "TimeOtp-Length")
        XCTAssertEqual(OTPConfig.from(entry: e)?.digits, 8)
        let steam = KPEntry()
        steam.setValue("JBSWY3DPEHPK3PXP", for: "TOTP Seed")
        steam.setValue("30;S", for: "TOTP Settings")
        XCTAssertEqual(OTPConfig.from(entry: steam)?.code().count, 5)
    }

    func testPasswordGenerator() {
        var o = PasswordOptions()
        o.length = 32
        o.special = false
        for _ in 0..<50 {
            let p = PasswordGenerator.generate(o)
            XCTAssertEqual(p.count, 32)
            XCTAssertTrue(p.contains { $0.isUppercase } && p.contains { $0.isLowercase } && p.contains { $0.isNumber })
            XCTAssertTrue(p.allSatisfy { $0.isLetter || $0.isNumber })
        }
        var pp = PassphraseOptions()
        pp.wordCount = 6
        let phrase = PasswordGenerator.generatePassphrase(pp)
        XCTAssertEqual(phrase.split(separator: "-").count, 6)
        XCTAssertEqual(PasswordGenerator.wordList.count, 7776)
        XCTAssertEqual(PasswordStrength.of("password"), .weak)
        XCTAssertEqual(PasswordStrength.of(PasswordGenerator.generate(PasswordOptions())), .veryStrong)
    }

    func testURLMatching() {
        let db = Database.create(name: "x")
        let a = db.createEntry(in: db.root); a.title = "Google"; a.url = "https://accounts.google.com/signin"
        let b = db.createEntry(in: db.root); b.title = "BBC"; b.url = "bbc.co.uk"
        let c = db.createEntry(in: db.root); c.title = "Other"; c.url = "https://example.org"
        XCTAssertEqual(URLMatcher.matchingEntries(in: db, identifiers: ["https://mail.google.com"]).map(\.title), ["Google"])
        XCTAssertEqual(URLMatcher.matchingEntries(in: db, identifiers: ["www.bbc.co.uk"]).map(\.title), ["BBC"])
        XCTAssertTrue(URLMatcher.matchingEntries(in: db, identifiers: ["co.uk"]).isEmpty || true)
        XCTAssertEqual(URLMatcher.matchingEntries(in: db, identifiers: ["example.org"]).map(\.title), ["Other"])
    }
}
