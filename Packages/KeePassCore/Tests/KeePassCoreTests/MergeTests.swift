// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import KeePassCore

final class MergeTests: XCTestCase {
    private let key = try! CompositeKey(password: "merge", keyFileData: nil)
    private var mailID = UUID()
    private var bankID = UUID()

    private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    private func stamp(_ times: inout Times, _ seconds: TimeInterval) {
        times.creation = t(seconds)
        times.lastModification = t(seconds)
        times.lastAccess = t(seconds)
        times.locationChanged = t(seconds)
    }

    /// A small database saved to bytes, so each test can open two independent copies of it.
    private func baseFile() throws -> Data {
        let settings = DatabaseSettings(kdf: .aes(rounds: 10, seed: Data(repeating: 7, count: 32)))
        let db = Database.create(name: "Base", settings: settings, groups: [("General", 48), ("Email", 19), ("Banking", 37)])
        let mail = db.createEntry(in: db.root.groups[0])
        mail.title = "Mail"
        mail.userName = "alex"
        mail.password = "one"
        mailID = mail.uuid
        let bank = db.createEntry(in: db.root.groups[2])
        bank.title = "Bank"
        bank.password = "pin"
        bankID = bank.uuid
        for g in db.allGroups { stamp(&g.times, 0) }
        for e in db.allEntries { stamp(&e.times, 0) }
        db.meta.databaseNameChanged = t(0)
        db.meta.settingsChanged = t(0)
        db.meta.recycleBinChanged = t(0)
        return try KDBX.save(db, key: key)
    }

    private func copies() throws -> (local: Database, remote: Database) {
        let data = try baseFile()
        return (try KDBX.open(data, key: key), try KDBX.open(data, key: key))
    }

    private func group(_ name: String, in db: Database) -> KPGroup {
        db.allGroups.first { $0.name == name }!
    }

    private func edit(_ entry: KPEntry, at seconds: TimeInterval, _ change: (KPEntry) -> Void) {
        entry.backupToHistory(maxItems: 10)
        change(entry)
        entry.times.lastModification = t(seconds)
    }

    // MARK: Entries

    func testNewerRemoteVersionWinsAndKeepsObjects() throws {
        let (local, remote) = try copies()
        let localMail = local.entry(uuid: mailID)!
        edit(remote.entry(uuid: mailID)!, at: 100) { $0.password = "two" }

        let summary = local.merge(from: remote)

        XCTAssertTrue(local.entry(uuid: mailID) === localMail, "the existing object is updated in place")
        XCTAssertEqual(localMail.password, "two")
        XCTAssertEqual(localMail.times.lastModification, t(100))
        XCTAssertEqual(localMail.history.map(\.password), ["one"], "the older version is kept once")
        XCTAssertEqual(summary.entriesUpdated, 1)
        XCTAssertEqual(summary.itemChanges, 1)
    }

    func testNewerLocalVersionStaysAndOlderRemoteGoesToHistory() throws {
        let (local, remote) = try copies()
        edit(local.entry(uuid: mailID)!, at: 200) { $0.password = "three" }
        edit(remote.entry(uuid: mailID)!, at: 100) { $0.password = "two" }

        let summary = local.merge(from: remote)

        let mail = local.entry(uuid: mailID)!
        XCTAssertEqual(mail.password, "three")
        XCTAssertEqual(mail.history.map(\.password), ["one", "two"])
        XCTAssertEqual(summary.entriesUpdated, 0)
        XCTAssertTrue(summary.historyChanged)
    }

    func testHistoryIsTrimmedToTheDatabaseLimit() throws {
        let (local, remote) = try copies()
        local.meta.historyMaxItems = 2
        let r = remote.entry(uuid: mailID)!
        for i in 1...4 { edit(r, at: TimeInterval(i * 10)) { $0.password = "v\(i)" } }

        local.merge(from: remote)

        let mail = local.entry(uuid: mailID)!
        XCTAssertEqual(mail.password, "v4")
        XCTAssertEqual(mail.history.map(\.password), ["v2", "v3"])
    }

    // MARK: Locations and new items

    func testLocationFollowsTheLatestMove() throws {
        let (local, remote) = try copies()
        remote.move(remote.entry(uuid: mailID)!, to: group("Email", in: remote))
        remote.entry(uuid: mailID)!.times.locationChanged = t(50)
        local.move(local.entry(uuid: bankID)!, to: group("General", in: local))
        local.entry(uuid: bankID)!.times.locationChanged = t(60)
        remote.move(remote.entry(uuid: bankID)!, to: group("Email", in: remote))
        remote.entry(uuid: bankID)!.times.locationChanged = t(40)

        let summary = local.merge(from: remote)

        XCTAssertEqual(local.entry(uuid: mailID)!.parent?.name, "Email", "the remote move is newer")
        XCTAssertEqual(local.entry(uuid: bankID)!.parent?.name, "General", "the local move is newer")
        XCTAssertEqual(summary.entriesMoved, 1)
    }

    func testMissingGroupsAndEntriesAreAdded() throws {
        let (local, remote) = try copies()
        let work = remote.createGroup(named: "Work", in: remote.root)
        let vpn = remote.createEntry(in: work)
        vpn.title = "VPN"
        let newsletter = remote.createEntry(in: group("Email", in: remote))
        newsletter.title = "Newsletter"
        let localOnly = local.createEntry(in: local.root)
        localOnly.title = "Local only"

        let summary = local.merge(from: remote)

        let localWork = local.group(uuid: work.uuid)
        XCTAssertNotNil(localWork)
        XCTAssertTrue(localWork?.parent === local.root)
        XCTAssertEqual(localWork?.entries.map(\.title), ["VPN"])
        XCTAssertEqual(local.entry(uuid: newsletter.uuid)?.parent?.name, "Email")
        XCTAssertNotNil(local.entry(uuid: localOnly.uuid), "items only in this copy are kept")
        XCTAssertEqual(summary.groupsAdded, 1)
        XCTAssertEqual(summary.entriesAdded, 2)
    }

    func testRenamedGroupKeepsItsContents() throws {
        let (local, remote) = try copies()
        let banking = group("Banking", in: remote)
        banking.name = "Money"
        banking.times.lastModification = t(30)

        local.merge(from: remote)

        let localBanking = local.group(uuid: banking.uuid)!
        XCTAssertEqual(localBanking.name, "Money")
        XCTAssertEqual(localBanking.entries.map(\.uuid), [bankID])
    }

    // MARK: Deletions

    func testDeletionsAreApplied() throws {
        let (local, remote) = try copies()
        remote.deletePermanently(remote.entry(uuid: mailID)!)

        let summary = local.merge(from: remote)

        XCTAssertNil(local.entry(uuid: mailID))
        XCTAssertTrue(local.deletedObjects.contains { $0.uuid == mailID })
        XCTAssertEqual(summary.entriesDeleted, 1)
    }

    func testItemChangedAfterDeletionIsKept() throws {
        let (local, remote) = try copies()
        remote.entry(uuid: mailID)!.parent?.remove(remote.entry(uuid: mailID)!)
        remote.deletedObjects = [DeletedObject(uuid: mailID, deletionTime: t(100))]
        edit(local.entry(uuid: mailID)!, at: 200) { $0.password = "kept" }

        local.merge(from: remote)

        XCTAssertEqual(local.entry(uuid: mailID)?.password, "kept")
        XCTAssertFalse(local.deletedObjects.contains { $0.uuid == mailID })
    }

    func testDeletedGroupWithNewContentIsKept() throws {
        let (local, remote) = try copies()
        let email = group("Email", in: remote)
        remote.deletePermanently(email)
        let added = local.createEntry(in: group("Email", in: local))
        added.title = "Added later"

        local.merge(from: remote)

        XCTAssertNotNil(local.group(uuid: email.uuid), "it still holds an entry that was not deleted")
        XCTAssertNotNil(local.entry(uuid: added.uuid))

        let (local2, remote2) = try copies()
        remote2.deletePermanently(group("Email", in: remote2))
        local2.merge(from: remote2)
        XCTAssertNil(local2.group(uuid: email.uuid))
    }

    func testRemoteMoveToRecycleBinIsFollowed() throws {
        let (local, remote) = try copies()
        remote.delete(remote.entry(uuid: mailID)!)
        remote.entry(uuid: mailID)!.times.locationChanged = t(70)
        remote.meta.recycleBinChanged = t(70)

        local.merge(from: remote)

        let mail = local.entry(uuid: mailID)!
        XCTAssertTrue(local.isInRecycleBin(mail))
        XCTAssertEqual(local.recycleBin?.uuid, remote.recycleBin?.uuid)
    }

    // MARK: Metadata

    func testMetadataIconsAndSettings() throws {
        let (local, remote) = try copies()
        remote.meta.databaseName = "Renamed"
        remote.meta.databaseNameChanged = t(100)
        let icon = CustomIcon(data: Data([1, 2, 3]), name: "Star")
        remote.meta.customIcons.append(icon)
        remote.entry(uuid: mailID)!.customIconUUID = icon.uuid
        remote.entry(uuid: mailID)!.times.lastModification = t(100)
        remote.settings.kdf = .aes(rounds: 20, seed: Data(repeating: 9, count: 32))
        remote.meta.settingsChanged = t(100)

        let summary = local.merge(from: remote)

        XCTAssertEqual(local.meta.databaseName, "Renamed")
        XCTAssertEqual(local.meta.customIcon(icon.uuid)?.data, Data([1, 2, 3]))
        XCTAssertEqual(local.settings, remote.settings)
        XCTAssertTrue(summary.metadataChanged)
    }

    func testSettingsTieUsesThePreferredCopy() throws {
        let (local, remote) = try copies()
        remote.settings.kdf = .aes(rounds: 20, seed: Data(repeating: 9, count: 32))
        let original = local.settings

        local.merge(from: remote)
        XCTAssertEqual(local.settings, original)

        local.merge(from: remote, preferOtherSettingsOnTie: true)
        XCTAssertEqual(local.settings, remote.settings)
    }

    // MARK: Convergence

    func testTwoWayMergeConverges() throws {
        let (local, remote) = try copies()
        edit(local.entry(uuid: mailID)!, at: 100) { $0.userName = "alex@home" }
        edit(remote.entry(uuid: bankID)!, at: 110) { $0.password = "new pin" }

        local.merge(from: remote)
        XCTAssertNotEqual(local.contentFingerprint(), remote.contentFingerprint(), "the file lacks the local change")
        remote.merge(from: local)
        XCTAssertEqual(local.contentFingerprint(), remote.contentFingerprint())
        XCTAssertEqual(local.entry(uuid: mailID)?.userName, "alex@home")
        XCTAssertEqual(local.entry(uuid: bankID)?.password, "new pin")

        let again = local.merge(from: remote)
        XCTAssertEqual(again.itemChanges, 0)
        XCTAssertFalse(again.metadataChanged)
    }

    func testMergedDatabaseSavesAndReopens() throws {
        let (local, remote) = try copies()
        edit(remote.entry(uuid: mailID)!, at: 100) { $0.password = "two" }
        let extra = remote.createEntry(in: remote.root)
        extra.title = "Extra"
        local.merge(from: remote)

        let reopened = try KDBX.open(try KDBX.save(local, key: key), key: key)
        XCTAssertEqual(reopened.contentFingerprint(), local.contentFingerprint())
        XCTAssertEqual(reopened.entry(uuid: mailID)?.history.count, 1)
    }

    func testFingerprintIgnoresHistoryOrderAndAccessTimes() throws {
        let (a, b) = try copies()
        XCTAssertEqual(a.contentFingerprint(), b.contentFingerprint())
        let mail = b.entry(uuid: mailID)!
        mail.history.append(mail.copy(includeHistory: false))
        mail.times.lastAccess = t(999)
        mail.times.usageCount = 5
        b.root.groups[0].sortChildren { $0.title > $1.title }
        b.deletedObjects.append(DeletedObject(uuid: UUID(), deletionTime: t(5)))
        XCTAssertEqual(a.contentFingerprint(), b.contentFingerprint())

        mail.notes = "changed"
        XCTAssertNotEqual(a.contentFingerprint(), b.contentFingerprint())
    }

    // MARK: Mirroring

    func testAdoptContentMirrorsTheOtherCopy() throws {
        let (local, remote) = try copies()
        let localMail = local.entry(uuid: mailID)!
        let localGeneral = group("General", in: local)
        let localOnly = local.createEntry(in: local.root)
        localOnly.title = "Not in the file"
        edit(remote.entry(uuid: mailID)!, at: 100) { $0.password = "two" }
        remote.move(remote.entry(uuid: bankID)!, to: group("General", in: remote))
        let added = remote.createEntry(in: group("Email", in: remote))
        added.title = "New"

        local.adoptContent(of: remote)

        XCTAssertEqual(local.contentFingerprint(), remote.contentFingerprint())
        XCTAssertTrue(local.entry(uuid: mailID) === localMail)
        XCTAssertTrue(local.group(uuid: localGeneral.uuid) === localGeneral)
        XCTAssertEqual(localMail.password, "two")
        XCTAssertNil(local.entry(uuid: localOnly.uuid))
        XCTAssertNil(localOnly.parent)
        XCTAssertEqual(Set(localGeneral.entries.map(\.uuid)), [mailID, bankID])
    }

    // MARK: Conflict copies

    func testConflictCopyNames() {
        let name = "Passwords.kdbx"
        let copies = [
            "Passwords.kdbx.conflict1", "Passwords.kdbx.conflict12", "Passwords.conflict1.kdbx",
            "Passwords.kdbx..path1", "Passwords.kdbx.path2", "Passwords.kdbx.2025-11-24-conflict1",
            "Passwords.sync-conflict-20251124-101530-ABCDEF7.kdbx",
            "Passwords (Alex's conflicted copy 2025-11-24).kdbx",
            "Passwords (conflicted copy 2025-11-24 101530).kdbx",
            "Passwords (Konfliktkopie von Alex 2025-11-24).kdbx",
        ]
        for c in copies { XCTAssertTrue(SyncConflictCopies.isConflictCopy(c, of: name), c) }
        let others = [
            "Passwords.kdbx", "Passwords.old.kdbx", "Passwords 2.kdbx", "Passwords (1).kdbx",
            "Other.kdbx.conflict1", "Passwords_2025-11-24.kdbx", "Passwords.kdbx.bak", "Passwords.key",
        ]
        for o in others { XCTAssertFalse(SyncConflictCopies.isConflictCopy(o, of: name), o) }
        XCTAssertTrue(SyncConflictCopies.isConflictCopy("vault.sync-conflict-20251124-101530-ABCDEF7", of: "vault"))
        XCTAssertEqual(SyncConflictCopies.realName(ofPlaceholder: ".Passwords.kdbx.icloud"), "Passwords.kdbx")
        XCTAssertNil(SyncConflictCopies.realName(ofPlaceholder: "Passwords.kdbx"))
    }
}
