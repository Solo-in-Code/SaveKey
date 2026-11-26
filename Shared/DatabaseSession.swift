// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Combine
import SwiftUI
import KeePassCore

/// Why the file on disk could not be merged into the open database.
enum FileConflict: Equatable, Sendable {
    /// The new version was saved with a different password or key file.
    case differentKey
    /// The new version could not be read (the detail says why).
    case unreadable(String)
}

/// A copy of the database left by a sync tool, or by iCloud when two devices saved at the same time.
struct ConflictCopy: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A file next to the database (rclone bisync, Syncthing, Dropbox…), by name.
        case file(String)
        /// A version iCloud kept aside.
        case iCloudVersion(URL)
    }

    let kind: Kind
    let modified: Date?
    /// The device that saved an iCloud version.
    let device: String?

    var id: String {
        switch kind {
        case .file(let name): return "file:\(name):\(modified?.timeIntervalSince1970 ?? 0)"
        case .iCloudVersion(let url): return "version:\(url.absoluteString)"
        }
    }

    var displayName: String {
        switch kind {
        case .file(let name):
            return name
        case .iCloudVersion:
            if let device, !device.isEmpty { return String(localized: "iCloud version from \(device)") }
            return String(localized: "iCloud version")
        }
    }
}

/// What a look at the file on disk found.
private enum DiskRead: Sendable {
    /// The file looks the same as when it was last read or written.
    case unchanged
    /// Only the date or size changed; the content is the same.
    case sameContent(FileState)
    /// The version that was already found impossible to merge.
    case rejectedAgain
    /// A new version, opened with the session's key.
    case changed(Database, FileState, Data)
    /// A new version that can't be merged.
    case failed(FileConflict, FileState, Data)
    /// The file is missing or could not be read at all.
    case unavailable
}

/// An unlocked database. Views observe it; after mutating the model call `commit()`,
/// which refreshes the UI and saves the file in the background.
///
/// While the app is active the session also watches the file. Changes saved elsewhere (another device,
/// a sync tool) are merged in the way KeePassXC does it, and a read-only session shows the latest
/// version. Conflict copies left by sync tools can be merged too.
@MainActor
final class DatabaseSession: ObservableObject, Identifiable {
    let id = UUID()
    let reference: DatabaseReference
    let isReadOnly: Bool
    /// The database file. It switches to a folder when the user chooses one while unlocked.
    private(set) var file: ScopedFile
    var url: URL { file.url }

    @Published private(set) var database: Database
    @Published private(set) var isSaving = false
    @Published var saveError: String?
    /// The file changed elsewhere in a way that can't be merged; the user decides what to do.
    @Published var conflict: FileConflict?
    /// Another device or sync tool keeps putting back versions that lack this session's changes.
    @Published var showOverwriteWarning = false
    /// The file was replaced by a new copy and SaveKey needs its folder to keep following it.
    @Published private(set) var needsFolder = false
    /// Conflict copies next to the database that can be merged (writable sessions only).
    @Published private(set) var conflictCopies: [ConflictCopy] = []
    /// The conflict copy being merged.
    @Published private(set) var mergingCopyID: String?
    @Published var mergeError: String?

    private(set) var key: CompositeKey
    private var knownState: FileState?
    private var knownHash: Data?
    private var rejected: (state: FileState, hash: Data, reason: FileConflict)?
    private var pendingSave = false
    private var changeCount = 0
    private var savedChangeCount = 0
    private var editors: Set<UUID> = []
    private var watchTask: Task<Void, Never>?
    private var isChecking = false
    private var lastWrite: Date?
    /// Counts writes, so a look at the file that overlapped a save can be discarded.
    private var writeCount = 0
    /// Checks since the content was last read; metadata of files in the cloud can lag behind.
    private var checksSinceRead = 0
    private var overwriteStrikes = 0
    private var ignoredCopies: Set<String> = []

    /// How often the file is checked while the app is active.
    private static let watchInterval: UInt64 = 8_000_000_000

    init(reference: DatabaseReference, file: ScopedFile, database: Database, key: CompositeKey,
         fileState: FileState?, fileHash: Data?, readOnly: Bool) {
        self.reference = reference
        self.file = file
        self.database = database
        self.key = key
        self.knownState = fileState
        self.knownHash = fileHash
        self.isReadOnly = readOnly
    }

    static func open(reference: DatabaseReference, key: CompositeKey, readOnly: Bool) async throws -> DatabaseSession {
        let resolved = try reference.resolve()
        if resolved.refreshedBookmark != nil || resolved.refreshedFolderBookmark != nil {
            DatabaseLibrary.shared.storeRefreshedBookmarks(resolved, for: reference.id)
        }
        let file = resolved.file
        let folderName = reference.folderName
        let (db, state, hash) = try await Task.detached(priority: .userInitiated) { () throws -> (Database, FileState, Data) in
            let read: (data: Data, state: FileState)
            do {
                read = try FileAccess.read(file)
            } catch {
                throw DatabaseSession.explain(error, file: file, folderName: folderName)
            }
            guard KDBX.isKeePassFile(read.data) else { throw KDBXError.notAKeePassFile }
            return (try KDBX.open(read.data, key: key), read.state, Hash.sha256(read.data))
        }.value
        return DatabaseSession(reference: reference, file: file, database: db, key: key,
                               fileState: state, fileHash: hash, readOnly: readOnly)
    }

    /// Turns "no such file" and access errors into an explanation with a way out.
    nonisolated static func explain(_ error: Error, file: ScopedFile, folderName: String?) -> Error {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return error }
        let missing = ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError
        if file.followsFolder {
            return missing ? BookmarkError.notInFolder(file: file.fileName, folder: folderName ?? file.folder.lastPathComponent) : error
        }
        return missing || isAccessError(error) ? BookmarkError.fileReplaced(file.fileName) : error
    }

    nonisolated static func isAccessError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain &&
            [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code)
    }

    var displayName: String {
        database.meta.databaseName.isEmpty ? reference.name : database.meta.databaseName
    }

    /// Changes not written to the file yet.
    var hasUnsavedChanges: Bool { changeCount != savedChangeCount }

    /// Refreshes observers and persists the change.
    func commit() {
        objectWillChange.send()
        changeCount += 1
        guard !isReadOnly else { return }
        Task { await save() }
    }

    /// Notifies observers without saving (e.g. for purely visual changes).
    func refresh() { objectWillChange.send() }

    /// Edit screens call these (see `pausesFileSync`), so that changes from elsewhere aren't merged in
    /// under an open editor; they are merged when the edit is saved.
    func beginEditing(_ token: UUID) { editors.insert(token) }
    func endEditing(_ token: UUID) { editors.remove(token) }

    // MARK: Saving

    /// Saves the database. If the file was changed elsewhere since it was last read, that version is
    /// merged in first; `force` skips this and overwrites the file.
    func save(force: Bool = false) async {
        guard !isReadOnly else { return }
        if isSaving {
            pendingSave = true
            return
        }
        isSaving = true
        let startCount = changeCount
        var mergedChanges = false
        if !force {
            switch await readIfChanged(skipRejectedVersion: false, evenIfLooksUnchanged: false) {
            case .changed(let remote, let state, let hash):
                objectWillChange.send()
                let summary = database.merge(from: remote, preferOtherSettingsOnTie: true)
                remember(state, hash)
                mergedChanges = summary.itemChanges > 0 || summary.metadataChanged
            case .failed(let reason, let state, let hash):
                rejected = (state, hash, reason)
                stopSaving(because: reason)
                return
            case .rejectedAgain:
                if let reason = rejected?.reason {
                    stopSaving(because: reason)
                    return
                }
            case .sameContent(let state):
                knownState = state
            case .unchanged, .unavailable:
                break
            }
        }
        let db = database
        let key = self.key
        let file = self.file
        do {
            let (state, hash) = try await Task.detached(priority: .userInitiated) { () throws -> (FileState, Data) in
                let data = try KDBX.save(db, key: key)
                let written = try FileAccess.write(data, to: file)
                return (FileAccess.state(file) ?? written, Hash.sha256(data))
            }.value
            remember(state, hash)
            lastWrite = Date()
            writeCount += 1
            savedChangeCount = startCount
            needsFolder = false
            CredentialIdentities.update(for: database, reference: reference)
            if mergedChanges { ToastCenter.shared.show(String(localized: "Merged changes from another device")) }
        } catch {
            saveError = String(localized: "The database could not be saved: \(error.localizedDescription)")
            if !file.followsFolder && Self.isAccessError(error) { needsFolder = true }
        }
        isSaving = false
        if pendingSave {
            pendingSave = false
            await save()
        }
    }

    /// Waits for a save in progress, then saves.
    private func saveNow() async {
        while isSaving { try? await Task.sleep(nanoseconds: 100_000_000) }
        await save()
    }

    private func stopSaving(because reason: FileConflict) {
        conflict = reason
        isSaving = false
        pendingSave = false
    }

    private func remember(_ state: FileState, _ hash: Data) {
        knownState = state
        knownHash = hash
        rejected = nil
    }

    /// After the file changed in a way that couldn't be merged: look at it again.
    func tryAgainAfterConflict() async {
        rejected = nil
        conflict = nil
        if hasUnsavedChanges { await saveNow() } else { await checkFile() }
    }

    /// After the overwrite warning: save this version again.
    func saveAgainAfterOverwrite() async {
        overwriteStrikes = 0
        showOverwriteWarning = false
        await saveNow()
    }

    /// Follows the database by name inside `folder` from now on (chosen while unlocked).
    func useFolder(_ folder: URL) async {
        file = ScopedFile(url: folder.appendingPathComponent(file.fileName, isDirectory: false), scope: folder)
        needsFolder = false
        if hasUnsavedChanges { await saveNow() } else { await checkFile() }
    }

    // MARK: Watching the file

    /// Checks the file every few seconds; call when the database is shown and the app is active.
    func startWatching() {
        guard watchTask == nil else { return }
        checksSinceRead = Int.max // read the content on the first check
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let session = self else { return }
                    await session.checkFile()
                }
                try? await Task.sleep(nanoseconds: DatabaseSession.watchInterval)
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Looks for a version saved elsewhere and merges it in (a read-only session shows it as it is),
    /// then looks for conflict copies.
    func checkFile() async {
        guard !isChecking, !isSaving, editors.isEmpty, conflict == nil, !showOverwriteWarning, mergingCopyID == nil else { return }
        isChecking = true
        defer { isChecking = false }

        if !file.followsFolder && !needsFolder {
            do {
                _ = try reference.resolve()
            } catch BookmarkError.fileReplaced(_) {
                needsFolder = true
            } catch {}
        }

        // The date and size of a file in iCloud can lag behind its content, so now and then
        // (and when the app comes back) the content is read even if they look unchanged.
        let readContent = checksSinceRead >= 6
        checksSinceRead = readContent ? 0 : checksSinceRead + 1
        let writesBefore = writeCount
        let found = await readIfChanged(skipRejectedVersion: true, evenIfLooksUnchanged: readContent)
        // A save that happened meanwhile has already dealt with the file.
        guard writeCount == writesBefore else { return }
        switch found {
        case .changed(let remote, let state, let hash):
            // A save or an editor that started meanwhile merges when it saves.
            guard !isSaving, editors.isEmpty else { return }
            await apply(remote, state: state, hash: hash)
        case .failed(let reason, let state, let hash):
            rejected = (state, hash, reason)
            // A file still being synced can look damaged; only a new password needs a decision now.
            if reason == .differentKey { conflict = reason }
        case .sameContent(let state):
            knownState = state
        case .unchanged, .rejectedAgain, .unavailable:
            break
        }
        if !isReadOnly { await refreshConflictCopies() }
    }

    /// Reads the file when it looks different from the version last read or written
    /// (or always, with `evenIfLooksUnchanged`).
    private func readIfChanged(skipRejectedVersion: Bool, evenIfLooksUnchanged: Bool) async -> DiskRead {
        let file = self.file
        guard let state = await Task.detached(priority: .utility, operation: { FileAccess.state(file) }).value else {
            return .unavailable
        }
        guard evenIfLooksUnchanged || state.differs(from: knownState) else { return .unchanged }
        if skipRejectedVersion, let rejected, !state.differs(from: rejected.state) { return .rejectedAgain }
        let key = self.key
        let knownHash = self.knownHash
        let rejectedHash = rejected?.hash
        return await Task.detached(priority: .utility) { () -> DiskRead in
            let read: (data: Data, state: FileState)
            do {
                read = try FileAccess.read(file)
            } catch {
                return .unavailable
            }
            let hash = Hash.sha256(read.data)
            if hash == knownHash { return .sameContent(read.state) }
            if hash == rejectedHash { return .rejectedAgain }
            guard KDBX.isKeePassFile(read.data) else {
                return .failed(.unreadable(KDBXError.notAKeePassFile.localizedDescription), read.state, hash)
            }
            do {
                return .changed(try KDBX.open(read.data, key: key), read.state, hash)
            } catch KDBXError.invalidCredentials {
                return .failed(.differentKey, read.state, hash)
            } catch {
                return .failed(.unreadable(error.localizedDescription), read.state, hash)
            }
        }.value
    }

    /// Brings a version saved elsewhere into the open database.
    private func apply(_ remote: Database, state: FileState, hash: Data) async {
        remember(state, hash)
        objectWillChange.send()
        if isReadOnly {
            database.adoptContent(of: remote)
            ToastCenter.shared.show(String(localized: "Updated to the latest version"))
            return
        }
        let summary = database.merge(from: remote, preferOtherSettingsOnTie: true)
        if database.contentFingerprint() == remote.contentFingerprint() {
            overwriteStrikes = 0
            if summary.itemChanges > 0 || summary.metadataChanged {
                ToastCenter.shared.show(String(localized: "Updated with changes from another device"))
            }
            return
        }
        // The new version lacks changes made here, so save the merged result. If that keeps happening
        // right after SaveKey saved, something overwrites the file (such as a one-way copy): stop and warn.
        changeCount += 1
        if let lastWrite, Date().timeIntervalSince(lastWrite) < 120 {
            overwriteStrikes += 1
        } else {
            overwriteStrikes = 0
        }
        if overwriteStrikes >= 2 {
            showOverwriteWarning = true
            return
        }
        await save()
        if saveError == nil && conflict == nil {
            ToastCenter.shared.show(String(localized: "Merged changes from another device"))
        }
    }

    // MARK: Conflict copies

    private func refreshConflictCopies() async {
        let file = self.file
        let found = await Task.detached(priority: .utility) { DatabaseSession.findConflictCopies(file: file) }.value
        let visible = found.filter { !ignoredCopies.contains($0.id) }
        if visible != conflictCopies { conflictCopies = visible }
    }

    /// Conflict copies in the database's folder, and versions iCloud kept aside.
    nonisolated static func findConflictCopies(file: ScopedFile) -> [ConflictCopy] {
        var copies: [ConflictCopy] = []
        if file.followsFolder, let items = try? FileAccess.listFolder(file.folder) {
            for item in items where SyncConflictCopies.isConflictCopy(item.name, of: file.fileName) {
                copies.append(ConflictCopy(kind: .file(item.name), modified: item.modified, device: nil))
            }
        }
        let versions = file.accessing { NSFileVersion.unresolvedConflictVersionsOfItem(at: file.url) ?? [] }
        for version in versions {
            copies.append(ConflictCopy(kind: .iCloudVersion(version.url), modified: version.modificationDate,
                                       device: version.localizedNameOfSavingComputer))
        }
        return copies
    }

    /// Merges a conflict copy into the database, saves, and then moves the copy to the trash
    /// (or marks the iCloud version as resolved).
    func mergeConflictCopy(_ copy: ConflictCopy) async {
        guard !isReadOnly, mergingCopyID == nil else { return }
        mergingCopyID = copy.id
        defer { mergingCopyID = nil }
        let file = self.file
        let key = self.key
        let other: Database
        do {
            other = try await Task.detached(priority: .userInitiated) { () throws -> Database in
                let data: Data
                switch copy.kind {
                case .file(let name):
                    data = try FileAccess.read(ScopedFile(url: file.folder.appendingPathComponent(name), scope: file.scope)).data
                case .iCloudVersion(let url):
                    data = try file.accessing { try Data(contentsOf: url) }
                }
                guard KDBX.isKeePassFile(data) else { throw KDBXError.notAKeePassFile }
                return try KDBX.open(data, key: key)
            }.value
        } catch KDBXError.invalidCredentials {
            mergeError = String(localized: "“\(copy.displayName)” was saved with a different password or key file, so SaveKey can’t merge it. Merge it in KeePassXC, or delete it in the Files app.")
            return
        } catch {
            mergeError = error.localizedDescription
            return
        }

        objectWillChange.send()
        database.merge(from: other)
        changeCount += 1
        await saveNow()
        // Keep the copy until the merged database is safely saved.
        guard !hasUnsavedChanges, saveError == nil, conflict == nil else { return }

        let removed = await Task.detached(priority: .utility) { () -> Bool in
            switch copy.kind {
            case .file(let name):
                return (try? FileAccess.trash(ScopedFile(url: file.folder.appendingPathComponent(name), scope: file.scope))) != nil
            case .iCloudVersion(let url):
                return DatabaseSession.resolveVersion(url, of: file)
            }
        }.value
        ignoredCopies.insert(copy.id)
        conflictCopies.removeAll { $0.id == copy.id }
        switch (copy.kind, removed) {
        case (.file, true):
            ToastCenter.shared.show(String(localized: "Merged “\(copy.displayName)” and moved it to Recently Deleted"))
        case (.file, false):
            ToastCenter.shared.show(String(localized: "Merged “\(copy.displayName)”. Delete the copy in the Files app."))
        case (.iCloudVersion, _):
            ToastCenter.shared.show(String(localized: "Merged the iCloud version"))
        }
    }

    /// Hides a conflict copy until the database is locked.
    func ignoreConflictCopy(_ copy: ConflictCopy) {
        ignoredCopies.insert(copy.id)
        conflictCopies.removeAll { $0.id == copy.id }
    }

    /// Marks an iCloud conflict version as handled, and removes the kept versions once none is left.
    nonisolated private static func resolveVersion(_ versionURL: URL, of file: ScopedFile) -> Bool {
        file.accessing {
            var resolved = false
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file.url, options: [], error: &error) { url in
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] where version.url == versionURL {
                    version.isResolved = true
                    resolved = true
                }
                if (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty {
                    try? NSFileVersion.removeOtherVersionsOfItem(at: url)
                }
            }
            return resolved
        }
    }

    // MARK: Master key and settings

    func changeMasterKey(to newKey: CompositeKey) async {
        key = newKey
        database.meta.masterKeyChanged = Date()
        database.settings.kdf = database.settings.kdf.withNewSalt()
        if BiometricKeyStore.hasKey(for: reference.id) {
            try? BiometricKeyStore.store(newKey.rawKey, for: reference.id)
        }
        objectWillChange.send()
        changeCount += 1
        await saveNow()
    }

    /// Changes encryption settings; the next save re-derives the key, which may take a moment.
    func updateSettings(_ settings: DatabaseSettings) async {
        database.settings = settings
        database.meta.settingsChanged = Date()
        objectWillChange.send()
        changeCount += 1
        await saveNow()
    }

    // MARK: Convenience

    var recycleBin: KPGroup? { database.recycleBin }

    func customIcon(_ uuid: UUID?) -> CustomIcon? { database.meta.customIcon(uuid) }

    func historyLimits() -> (Int, Int) { (database.meta.historyMaxItems, database.meta.historyMaxSize) }
}

extension View {
    /// Pauses merging changes from elsewhere while this editor is on screen.
    func pausesFileSync(_ session: DatabaseSession) -> some View {
        modifier(PausesFileSync(session: session))
    }
}

private struct PausesFileSync: ViewModifier {
    let session: DatabaseSession
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { session.beginEditing(token) }
            .onDisappear { session.endEditing(token) }
    }
}
