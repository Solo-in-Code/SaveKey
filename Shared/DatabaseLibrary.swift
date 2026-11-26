// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Combine

/// A database file the user has opened before, remembered via a bookmark so it can be
/// reopened from any location (On My iPhone, iCloud Drive, Dropbox, …) and from AutoFill.
struct DatabaseReference: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var fileName: String
    var bookmark: Data
    /// When set, SaveKey finds the database by `fileName` inside this folder, so it keeps working
    /// when a sync tool replaces the file with a new copy.
    var folderBookmark: Data?
    var folderName: String?
    var keyFileBookmark: Data?
    var keyFileName: String?
    var lastOpened: Date?
    /// "Open read-only" as chosen the last time the database was unlocked.
    var opensReadOnly: Bool?

    var followsFolder: Bool { folderBookmark != nil }

    /// Finds the database file: inside the followed folder, or through the file's own bookmark.
    func resolve() throws -> ResolvedDatabase {
        if let folderBookmark {
            var stale = false
            let folder: URL
            do {
                folder = try URL(resolvingBookmarkData: folderBookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw BookmarkError.folderUnavailable(folderName ?? "")
            }
            if FileAccess.isInTrash(folder) { throw BookmarkError.folderUnavailable(folderName ?? folder.lastPathComponent) }
            let file = ScopedFile(url: folder.appendingPathComponent(fileName, isDirectory: false), scope: folder)
            return ResolvedDatabase(file: file, refreshedFolderBookmark: stale ? try? Bookmarks.make(for: folder) : nil)
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw BookmarkError.fileReplaced(fileName)
        }
        // A sync tool that replaces the file (moving the old one to the trash) leaves the bookmark
        // pointing at the old copy in the trash.
        if FileAccess.isInTrash(url) { throw BookmarkError.fileReplaced(fileName) }
        return ResolvedDatabase(file: ScopedFile(url: url), refreshedBookmark: stale ? try? Bookmarks.make(for: url) : nil)
    }

    func resolveKeyFileURL() -> URL? {
        guard let keyFileBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: keyFileBookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// Where a database file is, plus fresh bookmark data when the stored bookmark was stale.
struct ResolvedDatabase {
    let file: ScopedFile
    var refreshedBookmark: Data?
    var refreshedFolderBookmark: Data?
}

enum BookmarkError: LocalizedError {
    case cannotAccess
    /// The bookmark leads to a file that was moved to the trash, renamed or replaced.
    case fileReplaced(String)
    /// The followed folder no longer contains the file.
    case notInFolder(file: String, folder: String)
    /// The followed folder can't be found.
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .cannotAccess:
            return String(localized: "The file could not be accessed. Try opening it again from Files.")
        case .fileReplaced(let name):
            return String(localized: "“\(name)” was replaced by a new copy, moved or renamed, so SaveKey can’t find it. Choose the folder that contains it, and SaveKey will follow the file by its name from now on.")
        case .notInFolder(let file, let folder):
            return String(localized: "“\(file)” is no longer in the folder “\(folder)”. If it was renamed, use “Follow in folder…” in the list of databases and pick it.")
        case .folderUnavailable(let folder):
            return String(localized: "The folder “\(folder)” can’t be found. Choose it again.")
        }
    }

    /// Choosing the folder (again) fixes the problem.
    var isFixedByChoosingFolder: Bool {
        if case .cannotAccess = self { return false }
        return true
    }
}

enum Bookmarks {
    /// Bookmark data for `url`, made while `scope` (the url itself by default) is accessible.
    static func make(for url: URL, scope: URL? = nil) throws -> Data {
        let target = scope ?? url
        let scoped = target.startAccessingSecurityScopedResource()
        defer { if scoped { target.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

@MainActor
final class DatabaseLibrary: ObservableObject {
    static let shared = DatabaseLibrary()

    @Published private(set) var references: [DatabaseReference] = []
    private let storageKey = "databases.v1"
    private let lastUsedKey = "databases.lastUsed"

    init() { reload() }

    func reload() {
        guard let data = AppConfig.sharedDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DatabaseReference].self, from: data) else {
            references = []
            return
        }
        references = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(references) {
            AppConfig.sharedDefaults.set(data, forKey: storageKey)
        }
    }

    var lastUsedID: UUID? {
        get { AppConfig.sharedDefaults.string(forKey: lastUsedKey).flatMap(UUID.init(uuidString:)) }
        set { AppConfig.sharedDefaults.set(newValue?.uuidString, forKey: lastUsedKey) }
    }

    /// Adds a database file (or returns the existing reference for the same file).
    @discardableResult
    func add(url: URL) throws -> DatabaseReference {
        let bookmark = try Bookmarks.make(for: url)
        let path = url.standardizedFileURL.path
        let fileName = url.lastPathComponent
        // The same file, or an entry whose file a sync tool replaced: link it again instead of adding a duplicate.
        if let idx = references.firstIndex(where: { ref in
            do {
                return try ref.resolve().file.url.standardizedFileURL.path == path
            } catch BookmarkError.fileReplaced(let name) {
                return name == fileName
            } catch {
                return false
            }
        }) {
            if !references[idx].followsFolder { references[idx].bookmark = bookmark }
            persist()
            return references[idx]
        }
        let name = url.deletingPathExtension().lastPathComponent
        let ref = DatabaseReference(name: name, fileName: url.lastPathComponent, bookmark: bookmark)
        references.append(ref)
        persist()
        return ref
    }

    /// Adds a database that SaveKey follows by name inside `folder`. An existing entry for the same
    /// file, or one whose file was replaced by a sync tool, is switched to the folder instead.
    @discardableResult
    func add(folder: URL, fileName: String) throws -> DatabaseReference {
        let path = folder.appendingPathComponent(fileName).standardizedFileURL.path
        if let idx = references.firstIndex(where: { ref in
            guard let resolved = try? ref.resolve() else { return ref.fileName == fileName }
            return resolved.file.url.standardizedFileURL.path == path
        }) {
            return try follow(references[idx], inFolder: folder, fileName: fileName)
        }
        let (folderBookmark, fileBookmark) = try bookmarks(folder: folder, fileName: fileName)
        var ref = DatabaseReference(name: (fileName as NSString).deletingPathExtension, fileName: fileName, bookmark: fileBookmark)
        ref.folderBookmark = folderBookmark
        ref.folderName = folder.lastPathComponent
        references.append(ref)
        persist()
        return ref
    }

    /// Makes a database follow its file by name inside `folder` from now on.
    @discardableResult
    func follow(_ ref: DatabaseReference, inFolder folder: URL, fileName: String) throws -> DatabaseReference {
        guard let idx = references.firstIndex(where: { $0.id == ref.id }) else { throw BookmarkError.cannotAccess }
        let (folderBookmark, fileBookmark) = try bookmarks(folder: folder, fileName: fileName)
        references[idx].folderBookmark = folderBookmark
        references[idx].folderName = folder.lastPathComponent
        references[idx].fileName = fileName
        references[idx].bookmark = fileBookmark
        persist()
        return references[idx]
    }

    private func bookmarks(folder: URL, fileName: String) throws -> (folder: Data, file: Data) {
        let folderBookmark = try Bookmarks.make(for: folder)
        let fileBookmark = (try? Bookmarks.make(for: folder.appendingPathComponent(fileName), scope: folder)) ?? folderBookmark
        return (folderBookmark, fileBookmark)
    }

    /// Remembers the "Open read-only" choice for the next unlock.
    func setOpensReadOnly(_ readOnly: Bool, for ref: DatabaseReference) {
        guard let idx = references.firstIndex(where: { $0.id == ref.id }),
              (references[idx].opensReadOnly ?? false) != readOnly else { return }
        references[idx].opensReadOnly = readOnly
        persist()
    }

    /// Stores bookmark data that iOS reported as stale and that was made again.
    func storeRefreshedBookmarks(_ resolved: ResolvedDatabase, for id: UUID) {
        guard let idx = references.firstIndex(where: { $0.id == id }) else { return }
        if let data = resolved.refreshedBookmark { references[idx].bookmark = data }
        if let data = resolved.refreshedFolderBookmark { references[idx].folderBookmark = data }
        persist()
    }

    func update(_ ref: DatabaseReference) {
        guard let idx = references.firstIndex(where: { $0.id == ref.id }) else { return }
        references[idx] = ref
        persist()
    }

    func remove(_ ref: DatabaseReference) {
        references.removeAll { $0.id == ref.id }
        BiometricKeyStore.delete(for: ref.id)
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        references.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func markOpened(_ ref: DatabaseReference) {
        guard let idx = references.firstIndex(where: { $0.id == ref.id }) else { return }
        references[idx].lastOpened = Date()
        lastUsedID = ref.id
        persist()
    }

    func setKeyFile(_ url: URL?, for ref: DatabaseReference) {
        guard let idx = references.firstIndex(where: { $0.id == ref.id }) else { return }
        if let url, let bm = try? Bookmarks.make(for: url) {
            references[idx].keyFileBookmark = bm
            references[idx].keyFileName = url.lastPathComponent
        } else {
            references[idx].keyFileBookmark = nil
            references[idx].keyFileName = nil
        }
        persist()
    }

    func reference(id: UUID) -> DatabaseReference? { references.first { $0.id == id } }
}
