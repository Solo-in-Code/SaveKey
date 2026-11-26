// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import KeePassCore

@MainActor
enum Report {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok {
            print("  ok  \(what)")
        } else {
            failures += 1
            print("FAIL  \(what) (line \(line))")
        }
    }
}

let T0 = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 100_000)
func at(_ seconds: TimeInterval) -> Date { T0.addingTimeInterval(seconds) }

/// Writes like rclone's iCloud backend: the old file goes to the trash and a new one is uploaded.
func replaceFile(_ url: URL, with data: Data, modified: Date) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    try data.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

func edit(_ entry: KPEntry, at seconds: TimeInterval, _ change: (KPEntry) -> Void) {
    entry.backupToHistory(maxItems: 10)
    change(entry)
    entry.times.lastModification = at(seconds)
}

@main
struct Scenario {
    @MainActor static func main() async throws {
        func check(_ ok: Bool, _ what: String, line: Int = #line) { Report.check(ok, what, line: line) }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("synccheck-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("KeePass", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let fileURL = folder.appendingPathComponent("Passwords.kdbx")
        let key = try CompositeKey(password: "pw", keyFileData: nil)
        let settings = DatabaseSettings(kdf: .aes(rounds: 10, seed: Data(repeating: 3, count: 32)))

        // The database as KeePassXC on the computer has it.
        let arch = Database.create(name: "Passwords", settings: settings, groups: [("General", 48), ("Email", 19)])
        let mail = arch.createEntry(in: arch.root.groups[0])
        mail.title = "Mail"
        mail.password = "one"
        let bank = arch.createEntry(in: arch.root.groups[1])
        bank.title = "Bank"
        bank.password = "pin"
        for g in arch.allGroups { g.times.lastModification = at(0); g.times.locationChanged = at(0) }
        for e in arch.allEntries { e.times.lastModification = at(0); e.times.locationChanged = at(0) }
        try replaceFile(fileURL, with: try KDBX.save(arch, key: key), modified: at(0))

        print("Bookmarks and folders")
        let library = DatabaseLibrary.shared
        let fileRef = try library.add(url: fileURL)
        try replaceFile(fileURL, with: try KDBX.save(arch, key: key), modified: at(1))
        do {
            _ = try fileRef.resolve()
            check(false, "a replaced file is reported")
        } catch BookmarkError.fileReplaced(let name) {
            check(name == "Passwords.kdbx", "a replaced file is reported")
        }
        let relinked = try library.add(url: fileURL)
        check(relinked.id == fileRef.id && library.references.count == 1, "picking the replaced file again links the same entry")
        check((try? relinked.resolve()) != nil, "and it opens again")
        try replaceFile(fileURL, with: try KDBX.save(arch, key: key), modified: at(2))
        check((try? relinked.resolve()) == nil, "until the next replacement")
        let ref = try library.follow(fileRef, inFolder: folder, fileName: "Passwords.kdbx")
        check(ref.followsFolder && ref.id == fileRef.id, "following the folder keeps the same database entry")
        check(try ref.resolve().file.url.standardizedFileURL.path == fileURL.standardizedFileURL.path,
              "the file is found by name in the folder")
        let again = try library.add(folder: folder, fileName: "Passwords.kdbx")
        check(again.id == ref.id && library.references.count == 1, "opening the same file from the folder adds no duplicate")
        library.setOpensReadOnly(true, for: ref)
        check(library.reference(id: ref.id)?.opensReadOnly == true, "the read-only choice is remembered")
        library.setOpensReadOnly(false, for: ref)
        do {
            var missing = ref
            missing.fileName = "Gone.kdbx"
            _ = try await DatabaseSession.open(reference: missing, key: key, readOnly: false)
            check(false, "a missing file is explained")
        } catch BookmarkError.notInFolder(let file, _) {
            check(file == "Gone.kdbx", "a missing file is explained")
        }

        print("Changes from the computer")
        let session = try await DatabaseSession.open(reference: library.reference(id: ref.id)!, key: key, readOnly: false)
        let localMail = session.database.entry(uuid: mail.uuid)!
        await session.checkFile()
        check(ToastCenter.shared.messages.isEmpty, "nothing happens while the file is unchanged")

        var remote = try KDBX.open(Data(contentsOf: fileURL), key: key)
        edit(remote.entry(uuid: mail.uuid)!, at: 100) { $0.password = "two" }
        try replaceFile(fileURL, with: try KDBX.save(remote, key: key), modified: at(100))
        let written = try Data(contentsOf: fileURL)
        await session.checkFile()
        check(localMail.password == "two", "a change made elsewhere is merged into the open entry")
        check(try Data(contentsOf: fileURL) == written, "no save-back when the file already has everything")
        check(ToastCenter.shared.messages.last == "Updated with changes from another device", "the update is announced")

        print("Saving merges first")
        edit(localMail, at: 200) { $0.userName = "alex@home" }
        remote = try KDBX.open(Data(contentsOf: fileURL), key: key)
        edit(remote.entry(uuid: bank.uuid)!, at: 210) { $0.password = "new pin" }
        try replaceFile(fileURL, with: try KDBX.save(remote, key: key), modified: at(210))
        session.commit()
        await waitForSave(session)
        var onDisk = try KDBX.open(Data(contentsOf: fileURL), key: key)
        check(onDisk.entry(uuid: mail.uuid)?.userName == "alex@home", "the local change is saved")
        check(onDisk.entry(uuid: bank.uuid)?.password == "new pin", "the change made elsewhere is kept when saving")
        check(session.database.entry(uuid: bank.uuid)?.password == "new pin", "and shown here")
        check(!session.hasUnsavedChanges && session.conflict == nil && session.saveError == nil, "saved without a conflict")

        print("A one-way copy keeps overwriting")
        let old = try KDBX.save(remote, key: key) // the computer's version, without "alex@home"
        try replaceFile(fileURL, with: old, modified: at(300))
        await session.checkFile()
        onDisk = try KDBX.open(Data(contentsOf: fileURL), key: key)
        check(onDisk.entry(uuid: mail.uuid)?.userName == "alex@home", "the first overwrite is repaired by saving the merge")
        check(!session.showOverwriteWarning, "no warning yet")
        try replaceFile(fileURL, with: old, modified: at(310))
        await session.checkFile()
        check(session.showOverwriteWarning, "a second overwrite right after saving shows the warning")
        check(localMail.userName == "alex@home", "the local change is kept on the iPhone")
        await session.saveAgainAfterOverwrite()
        onDisk = try KDBX.open(Data(contentsOf: fileURL), key: key)
        check(onDisk.entry(uuid: mail.uuid)?.userName == "alex@home" && !session.showOverwriteWarning, "Save again writes it back")

        print("Conflict copies")
        var copyDB = try KDBX.open(Data(contentsOf: fileURL), key: key)
        let fromCopy = copyDB.createEntry(in: copyDB.root)
        fromCopy.title = "Made on the computer"
        let copyURL = folder.appendingPathComponent("Passwords.kdbx.conflict1")
        try replaceFile(copyURL, with: try KDBX.save(copyDB, key: key), modified: at(400))
        try replaceFile(folder.appendingPathComponent("Passwords.old.kdbx"), with: old, modified: at(400))
        await session.checkFile()
        check(session.conflictCopies.map(\.displayName) == ["Passwords.kdbx.conflict1"], "the conflict copy is found, backups are not")
        if let copy = session.conflictCopies.first { await session.mergeConflictCopy(copy) }
        onDisk = try KDBX.open(Data(contentsOf: fileURL), key: key)
        check(onDisk.entry(uuid: fromCopy.uuid) != nil, "its entry is merged and saved")
        check(!fm.fileExists(atPath: copyURL.path), "the copy is moved to the trash")
        check(session.conflictCopies.isEmpty, "and no longer offered")
        check(ToastCenter.shared.messages.last == "Merged “Passwords.kdbx.conflict1” and moved it to Recently Deleted", "the merge is announced")

        print("iCloud conflict versions")
        copyDB = try KDBX.open(Data(contentsOf: fileURL), key: key)
        let fromVersion = copyDB.createEntry(in: copyDB.root)
        fromVersion.title = "Saved on the iPad"
        let versionURL = base.appendingPathComponent("version-1.kdbx")
        try KDBX.save(copyDB, key: key).write(to: versionURL)
        NSFileVersion.conflicts[fileURL.standardizedFileURL.path] = [NSFileVersion(url: versionURL, modificationDate: at(500), device: "iPad")]
        await session.checkFile()
        check(session.conflictCopies.map(\.displayName) == ["iCloud version from iPad"], "an iCloud conflict version is offered")
        if let copy = session.conflictCopies.first { await session.mergeConflictCopy(copy) }
        check(session.database.entry(uuid: fromVersion.uuid) != nil, "its entry is merged")
        check(NSFileVersion.conflicts[fileURL.standardizedFileURL.path] == nil, "the version is resolved and removed")

        print("A new password elsewhere")
        let otherKey = try CompositeKey(password: "changed", keyFileData: nil)
        try replaceFile(fileURL, with: try KDBX.save(onDisk, key: otherKey), modified: at(600))
        await session.checkFile()
        check(session.conflict == .differentKey, "a file with another password asks what to do")
        session.conflict = nil
        await session.checkFile()
        check(session.conflict == nil, "it does not ask again for the same version")
        session.commit()
        await waitForSave(session)
        check(session.conflict == .differentKey, "saving over it needs a decision")
        session.conflict = nil
        await session.save(force: true)
        check((try? KDBX.open(Data(contentsOf: fileURL), key: key))?.entry(uuid: mail.uuid) != nil, "Overwrite writes this version")

        print("Read-only sessions mirror the file")
        let viewer = try await DatabaseSession.open(reference: library.reference(id: ref.id)!, key: key, readOnly: true)
        let viewerMail = viewer.database.entry(uuid: mail.uuid)!
        remote = try KDBX.open(Data(contentsOf: fileURL), key: key)
        edit(remote.entry(uuid: mail.uuid)!, at: 700) { $0.password = "three" }
        remote.deletePermanently(remote.entry(uuid: bank.uuid)!)
        // An older backup restored elsewhere: entries vanish without deletion records.
        if let made = remote.allEntries.first(where: { $0.title == "Made on the computer" }) { made.parent?.remove(made) }
        try replaceFile(fileURL, with: try KDBX.save(remote, key: key), modified: at(700))
        await viewer.checkFile()
        check(viewer.database.entry(uuid: mail.uuid) === viewerMail && viewerMail.password == "three", "the open entry updates in place")
        check(viewer.database.contentFingerprint() == remote.contentFingerprint(), "the viewer shows exactly the file")
        check((try? KDBX.open(Data(contentsOf: fileURL), key: key))?.contentFingerprint() == remote.contentFingerprint(), "a viewer never writes")
        check(ToastCenter.shared.messages.last == "Updated to the latest version", "the reload is announced")

        print("Editors pause merging")
        let token = UUID()
        session.beginEditing(token)
        remote = try KDBX.open(Data(contentsOf: fileURL), key: key)
        edit(remote.entry(uuid: mail.uuid)!, at: 800) { $0.notes = "from elsewhere" }
        try replaceFile(fileURL, with: try KDBX.save(remote, key: key), modified: at(800))
        await session.checkFile()
        check(localMail.notes != "from elsewhere", "nothing is merged under an open editor")
        session.endEditing(token)
        await session.checkFile()
        check(localMail.notes == "from elsewhere", "merged once the editor closes")
        check(session.database.entry(uuid: bank.uuid) == nil, "a deletion made elsewhere is applied")
        onDisk = try KDBX.open(Data(contentsOf: fileURL), key: key)
        check(onDisk.allEntries.contains { $0.title == "Made on the computer" }, "an entry missing from a restored backup is saved back")

        print("Metadata that lags behind the content")
        let attributes = try fm.attributesOfItem(atPath: fileURL.path)
        let knownDate = attributes[.modificationDate] as! Date
        let knownSize = (attributes[.size] as! NSNumber).intValue
        remote = try KDBX.open(Data(contentsOf: fileURL), key: key)
        remote.entry(uuid: mail.uuid)!.notes = "from elsewherE"
        remote.entry(uuid: mail.uuid)!.times.lastModification = at(850)
        var sameSize: Data?
        for _ in 0..<200 {
            let candidate = try KDBX.save(remote, key: key)
            if candidate.count == knownSize { sameSize = candidate; break }
        }
        if let sameSize {
            try sameSize.write(to: fileURL)
            try fm.setAttributes([.modificationDate: knownDate], ofItemAtPath: fileURL.path)
            await session.checkFile()
            check(localMail.notes == "from elsewhere", "a change with the same date and size isn't seen at once")
            for _ in 0..<7 { await session.checkFile() }
            check(localMail.notes == "from elsewherE", "but the content is read every few checks")
        } else {
            print("  (skipped: no save with the same size)")
        }

        print("A damaged file")
        try replaceFile(fileURL, with: Data("half uploaded".utf8), modified: at(900))
        await session.checkFile()
        check(session.conflict == nil, "a damaged file found while watching is skipped quietly")
        session.commit()
        await waitForSave(session)
        if case .unreadable? = session.conflict { check(true, "saving over it asks first") } else { check(false, "saving over it asks first") }
        session.conflict = nil
        try replaceFile(fileURL, with: try KDBX.save(onDisk, key: key), modified: at(910))
        await session.tryAgainAfterConflict()
        check(session.conflict == nil && !session.hasUnsavedChanges, "Try again merges the repaired file and saves")

        print("A replaced file while unlocked")
        let folder2 = base.appendingPathComponent("Other", isDirectory: true)
        try fm.createDirectory(at: folder2, withIntermediateDirectories: true)
        let otherURL = folder2.appendingPathComponent("Other.kdbx")
        try replaceFile(otherURL, with: try KDBX.save(arch, key: key), modified: at(0))
        let linked = try library.add(url: otherURL)
        let s2 = try await DatabaseSession.open(reference: linked, key: key, readOnly: false)
        await s2.checkFile()
        check(!s2.needsFolder, "a linked file that is still there needs nothing")
        remote = try KDBX.open(Data(contentsOf: otherURL), key: key)
        edit(remote.entry(uuid: mail.uuid)!, at: 50) { $0.password = "replaced" }
        try replaceFile(otherURL, with: try KDBX.save(remote, key: key), modified: at(50))
        await s2.checkFile()
        check(s2.needsFolder, "a file replaced by a sync tool asks for its folder")
        try library.follow(linked, inFolder: folder2, fileName: "Other.kdbx")
        await s2.useFolder(folder2)
        check(!s2.needsFolder && s2.file.followsFolder, "choosing the folder follows the file by name")
        check(s2.database.entry(uuid: mail.uuid)?.password == "replaced", "and brings in the new version")

        print(Report.failures == 0 ? "\nAll checks passed" : "\n\(Report.failures) check(s) failed")
        if Report.failures > 0 { exit(1) }
    }

    @MainActor static func waitForSave(_ session: DatabaseSession) async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        while session.isSaving { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
