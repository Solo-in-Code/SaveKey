// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import KeePassCore

/// A file plus the item whose security scope gives access to it: the file itself, or the folder that
/// contains it when SaveKey follows a database by name inside a folder.
struct ScopedFile: Sendable, Equatable {
    let url: URL
    let scope: URL

    init(url: URL, scope: URL? = nil) {
        self.url = url
        self.scope = scope ?? url
    }

    /// The database is found by name inside a folder.
    var followsFolder: Bool { scope != url }
    var folder: URL { followsFolder ? scope : url.deletingLastPathComponent() }
    var fileName: String { url.lastPathComponent }

    /// Runs `body` while the security scope is open.
    func accessing<T>(_ body: () throws -> T) rethrows -> T {
        let scoped = scope.startAccessingSecurityScopedResource()
        defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

/// What change detection compares: the modification date and the size.
struct FileState: Equatable, Sendable {
    var modified: Date?
    var size: Int?

    /// Whether the file looks changed compared with `other` (dates more than a second apart,
    /// or a different size).
    func differs(from other: FileState?) -> Bool {
        guard let other else { return true }
        switch (modified, other.modified) {
        case let (a?, b?): if abs(a.timeIntervalSince(b)) > 1 { return true }
        case (nil, nil): break
        default: return true
        }
        if let a = size, let b = other.size, a != b { return true }
        return false
    }
}

/// A file in a folder, as listed for choosing a database.
struct FolderItem: Identifiable, Hashable, Sendable {
    let name: String
    let modified: Date?
    let size: Int?
    /// False for an iCloud file that is not downloaded yet.
    let isDownloaded: Bool
    var id: String { name }
}

/// Coordinated, security-scoped file I/O that works with any Files provider.
/// All methods block, so call them off the main thread.
enum FileAccess {
    static func read(_ file: ScopedFile) throws -> (data: Data, state: FileState) {
        try file.accessing {
            prepareDownload(of: file)
            var coordinationError: NSError?
            var result: Result<(Data, FileState), Error> = .failure(BookmarkError.cannotAccess)
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file.url, options: [], error: &coordinationError) { readURL in
                do {
                    let data = try Data(contentsOf: readURL)
                    let values = try? readURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    result = .success((data, FileState(modified: values?.contentModificationDate, size: values?.fileSize ?? data.count)))
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError { throw coordinationError }
            let value = try result.get()
            return (value.0, value.1)
        }
    }

    /// The modification date and size as currently known, without downloading; nil if the file is missing.
    static func state(_ file: ScopedFile) -> FileState? {
        file.accessing {
            var state: FileState?
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file.url, options: [.immediatelyAvailableMetadataOnly], error: &error) { u in
                if let values = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                    state = FileState(modified: values.contentModificationDate, size: values.fileSize)
                }
            }
            if state == nil, file.followsFolder, isPlaceholderPresent(for: file) {
                // Not downloaded yet: report the placeholder so a change still shows up.
                let placeholder = placeholderURL(for: file.url)
                let values = try? placeholder.resourceValues(forKeys: [.contentModificationDateKey])
                state = FileState(modified: values?.contentModificationDate, size: nil)
            }
            return state
        }
    }

    /// Writes data in place and returns the new modification date and size.
    @discardableResult
    static func write(_ data: Data, to file: ScopedFile) throws -> FileState {
        try file.accessing {
            var coordinationError: NSError?
            var writeError: Error?
            var state = FileState(modified: nil, size: data.count)
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file.url, options: [.forReplacing], error: &coordinationError) { writeURL in
                do {
                    do {
                        try data.write(to: writeURL, options: [.atomic])
                    } catch {
                        // Some providers do not allow atomic replacement; fall back to an in-place write.
                        try data.write(to: writeURL, options: [])
                    }
                    let values = try? writeURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    state = FileState(modified: values?.contentModificationDate, size: values?.fileSize ?? data.count)
                } catch {
                    writeError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
            return state
        }
    }

    /// Moves a file to the trash ("Recently Deleted" in Files) after coordinating with other writers.
    static func trash(_ file: ScopedFile) throws {
        try file.accessing {
            var coordinationError: NSError?
            var trashError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file.url, options: [.forDeleting], error: &coordinationError) { u in
                do {
                    try FileManager.default.trashItem(at: u, resultingItemURL: nil)
                } catch {
                    trashError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let trashError { throw trashError }
        }
    }

    /// The files in a folder (not subfolders), with iCloud placeholders shown under their real names.
    static func listFolder(_ folder: URL) throws -> [FolderItem] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        var items: [String: FolderItem] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            let name = url.lastPathComponent
            if let real = SyncConflictCopies.realName(ofPlaceholder: name) {
                if items[real] == nil {
                    items[real] = FolderItem(name: real, modified: values?.contentModificationDate, size: nil, isDownloaded: false)
                }
            } else if !name.hasPrefix(".") {
                items[name] = FolderItem(name: name, modified: values?.contentModificationDate, size: values?.fileSize, isDownloaded: true)
            }
        }
        return items.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether a bookmark led into a trash folder, which happens when a sync tool replaced the file.
    static func isInTrash(_ url: URL) -> Bool { url.path.contains("/.Trash/") }

    /// Whether the file exists in its folder (downloaded or as an iCloud placeholder).
    static func exists(_ file: ScopedFile) -> Bool {
        file.accessing {
            FileManager.default.fileExists(atPath: file.url.path) || isPlaceholderPresent(for: file)
        }
    }

    // MARK: URL conveniences (files picked in Files)

    static func read(_ url: URL) throws -> (data: Data, state: FileState) { try read(ScopedFile(url: url)) }
    static func state(_ url: URL) -> FileState? { state(ScopedFile(url: url)) }

    /// Reads a file that the user just picked (fileImporter URL).
    static func readPicked(_ url: URL) throws -> Data { try read(url).data }

    // MARK: iCloud placeholders

    private static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    private static func isPlaceholderPresent(for file: ScopedFile) -> Bool {
        FileManager.default.fileExists(atPath: placeholderURL(for: file.url).path)
    }

    /// Asks iCloud to download a file that is only a placeholder; the coordinated read then waits for it.
    private static func prepareDownload(of file: ScopedFile) {
        guard !FileManager.default.fileExists(atPath: file.url.path), isPlaceholderPresent(for: file) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: file.url)
    }
}
