// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import KeePassCore

// Stand-ins for the Apple-only APIs and app types the sync code uses, so it can be type-checked
// and exercised on Linux.

extension String {
    init(localized key: String) { self = key }
}

/// Simulates iOS bookmarks: they identify the file itself (its inode here), so they follow it into
/// the trash when a sync tool replaces it with a new file of the same name.
enum BookmarkSim {
    nonisolated(unsafe) static var moved: [UInt64: String] = [:]

    static func inode(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

extension URL {
    struct BookmarkCreationOptions: OptionSet { let rawValue: Int }
    struct BookmarkResolutionOptions: OptionSet { let rawValue: Int }

    func startAccessingSecurityScopedResource() -> Bool { true }
    func stopAccessingSecurityScopedResource() {}

    func bookmarkData(options: BookmarkCreationOptions = [], includingResourceValuesForKeys keys: Set<URLResourceKey>? = nil,
                      relativeTo url: URL? = nil) throws -> Data {
        let path = standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
        return Data("\(BookmarkSim.inode(path))|\(path)".utf8)
    }

    init(resolvingBookmarkData data: Data, options: BookmarkResolutionOptions = [], relativeTo url: URL? = nil,
         bookmarkDataIsStale: inout Bool) throws {
        let parts = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let inode = UInt64(parts[0]) else { throw CocoaError(.fileReadCorruptFile) }
        let path = BookmarkSim.moved[inode] ?? parts[1]
        guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
        self = URL(fileURLWithPath: path)
    }
}

extension FileManager {
    func trashItem(at url: URL, resultingItemURL outResultingURL: UnsafeMutablePointer<NSURL?>?) throws {
        let trash = url.deletingLastPathComponent().appendingPathComponent(".Trash", isDirectory: true)
        try createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(url.lastPathComponent)")
        let inode = BookmarkSim.inode(url.standardizedFileURL.path)
        try moveItem(at: url, to: destination)
        BookmarkSim.moved[inode] = destination.standardizedFileURL.path
    }

    func startDownloadingUbiquitousItem(at url: URL) throws {}
}

final class NSFileCoordinator {
    struct ReadingOptions: OptionSet {
        let rawValue: Int
        static let immediatelyAvailableMetadataOnly = ReadingOptions(rawValue: 1)
    }
    struct WritingOptions: OptionSet {
        let rawValue: Int
        static let forReplacing = WritingOptions(rawValue: 1)
        static let forDeleting = WritingOptions(rawValue: 2)
    }

    init(filePresenter: Any?) {}

    func coordinate(readingItemAt url: URL, options: ReadingOptions = [], error outError: UnsafeMutablePointer<NSError?>?,
                    byAccessor reader: (URL) -> Void) {
        reader(url)
    }

    func coordinate(writingItemAt url: URL, options: WritingOptions = [], error outError: UnsafeMutablePointer<NSError?>?,
                    byAccessor writer: (URL) -> Void) {
        writer(url)
    }
}

final class NSFileVersion {
    nonisolated(unsafe) static var conflicts: [String: [NSFileVersion]] = [:]

    let url: URL
    let modificationDate: Date?
    let localizedNameOfSavingComputer: String?
    var isResolved = false

    init(url: URL, modificationDate: Date?, device: String?) {
        self.url = url
        self.modificationDate = modificationDate
        self.localizedNameOfSavingComputer = device
    }

    static func unresolvedConflictVersionsOfItem(at url: URL) -> [NSFileVersion]? {
        conflicts[url.standardizedFileURL.path]?.filter { !$0.isResolved }
    }

    static func removeOtherVersionsOfItem(at url: URL) throws {
        conflicts[url.standardizedFileURL.path] = nil
    }
}

enum AppConfig {
    static let sharedDefaults = UserDefaults(suiteName: "synccheck-\(ProcessInfo.processInfo.processIdentifier)")!
}

enum BiometricKeyStore {
    static func delete(for id: UUID) {}
    static func hasKey(for id: UUID) -> Bool { false }
    static func store(_ key: Data, for id: UUID) throws {}
}

enum CredentialIdentities {
    @MainActor static func update(for db: Database, reference: DatabaseReference) {}
}

@MainActor
final class ToastCenter {
    static let shared = ToastCenter()
    var messages: [String] = []
    func show(_ text: String) { messages.append(text) }
}
