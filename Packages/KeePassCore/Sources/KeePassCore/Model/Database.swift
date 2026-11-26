// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public final class Database {
    public var meta: Meta
    public var root: KPGroup
    public var deletedObjects: [DeletedObject] = []
    public var settings: DatabaseSettings
    /// Raw KDBX 4 "public custom data" header field, preserved as-is.
    public var publicCustomData: Data?

    /// Cache of the derived key so saving does not re-run the (slow) KDF.
    var transformCache: (rawKey: Data, kdf: KDFParameters, transformed: Data)?

    public init(meta: Meta, root: KPGroup, settings: DatabaseSettings) {
        self.meta = meta
        self.root = root
        self.settings = settings
    }

    /// Starter folders (name, standard icon) for a new database. The app passes translated names.
    public static let defaultGroups: [(name: String, iconID: Int)] = [
        ("General", 48), ("Email", 19), ("Internet", 1), ("Banking", 37), ("Notes", 7),
    ]

    /// Creates an empty database with a few starter groups, like KeePass does.
    public static func create(name: String, settings: DatabaseSettings = DatabaseSettings(),
                              groups: [(name: String, iconID: Int)] = Database.defaultGroups) -> Database {
        let meta = Meta()
        meta.databaseName = name
        meta.settingsChanged = Date.keepassNow
        let root = KPGroup(name: name.isEmpty ? "Database" : name)
        root.iconID = 49
        let db = Database(meta: meta, root: root, settings: settings)
        for (title, icon) in groups {
            let g = KPGroup(name: title)
            g.iconID = icon
            root.add(g)
        }
        return db
    }

    // MARK: Lookup

    public var allEntries: [KPEntry] { root.allEntries }
    public var allGroups: [KPGroup] { [root] + root.allGroups }

    public func entry(uuid: UUID) -> KPEntry? { allEntries.first { $0.uuid == uuid } }
    public func group(uuid: UUID) -> KPGroup? { allGroups.first { $0.uuid == uuid } }

    public var recycleBin: KPGroup? {
        guard meta.recycleBinUUID != .zero else { return nil }
        return group(uuid: meta.recycleBinUUID)
    }

    public func isInRecycleBin(_ entry: KPEntry) -> Bool {
        guard let bin = recycleBin, let parent = entry.parent else { return false }
        return parent === bin || parent.isDescendant(of: bin)
    }

    public func isInRecycleBin(_ group: KPGroup) -> Bool {
        guard let bin = recycleBin else { return false }
        return group === bin || group.isDescendant(of: bin)
    }

    /// Entries visible to search: excludes the recycle bin and groups with searching disabled.
    public var searchableEntries: [KPEntry] {
        allEntries.filter { e in
            !isInRecycleBin(e) && (e.parent?.isSearchable ?? true)
        }
    }

    /// Case- and diacritic-insensitive search over the common fields, tags and custom fields.
    public func search(_ query: String) -> [KPEntry] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return searchableEntries.filter { entry in
            let haystack = ([entry.title, entry.userName, entry.url, entry.notes, entry.tags.joined(separator: " ")] +
                entry.customFields.filter { !$0.isProtected }.map(\.value)).joined(separator: "\n")
            return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: Mutations

    @discardableResult
    public func createEntry(in group: KPGroup) -> KPEntry {
        let e = KPEntry()
        e.iconID = 0
        e.setValue("", for: KPEntry.titleKey, protected: meta.memoryProtection.protectTitle)
        e.setValue(meta.defaultUserName, for: KPEntry.userNameKey, protected: meta.memoryProtection.protectUserName)
        e.setValue("", for: KPEntry.passwordKey, protected: meta.memoryProtection.protectPassword)
        e.setValue("", for: KPEntry.urlKey, protected: meta.memoryProtection.protectURL)
        e.setValue("", for: KPEntry.notesKey, protected: meta.memoryProtection.protectNotes)
        group.add(e)
        return e
    }

    @discardableResult
    public func createGroup(named name: String, in parent: KPGroup) -> KPGroup {
        let g = KPGroup(name: name)
        g.iconID = parent === root ? 48 : parent.iconID
        parent.add(g)
        return g
    }

    public func move(_ entry: KPEntry, to group: KPGroup) {
        guard entry.parent !== group else { return }
        entry.previousParentGroup = entry.parent?.uuid
        group.add(entry)
        entry.times.locationChanged = Date.keepassNow
    }

    /// Returns false if the move would create a cycle.
    @discardableResult
    public func move(_ group: KPGroup, to newParent: KPGroup) -> Bool {
        guard group !== root, group !== newParent, !newParent.isDescendant(of: group) else { return false }
        group.previousParentGroup = group.parent?.uuid
        newParent.add(group)
        group.times.locationChanged = Date.keepassNow
        return true
    }

    /// Moves to the recycle bin when enabled, otherwise deletes permanently.
    public func delete(_ entry: KPEntry) {
        if meta.recycleBinEnabled && !isInRecycleBin(entry) {
            move(entry, to: ensureRecycleBin())
        } else {
            deletePermanently(entry)
        }
    }

    public func delete(_ group: KPGroup) {
        guard group !== root else { return }
        if meta.recycleBinEnabled && !isInRecycleBin(group) {
            move(group, to: ensureRecycleBin())
        } else {
            deletePermanently(group)
        }
    }

    public func deletePermanently(_ entry: KPEntry) {
        entry.parent?.remove(entry)
        deletedObjects.append(DeletedObject(uuid: entry.uuid, deletionTime: Date.keepassNow))
    }

    public func deletePermanently(_ group: KPGroup) {
        guard group !== root else { return }
        for e in group.allEntries { deletedObjects.append(DeletedObject(uuid: e.uuid, deletionTime: Date.keepassNow)) }
        for g in [group] + group.allGroups { deletedObjects.append(DeletedObject(uuid: g.uuid, deletionTime: Date.keepassNow)) }
        if meta.recycleBinUUID == group.uuid {
            meta.recycleBinUUID = .zero
            meta.recycleBinChanged = Date.keepassNow
        }
        group.parent?.remove(group)
    }

    public func emptyRecycleBin() {
        guard let bin = recycleBin else { return }
        for e in bin.entries { deletePermanently(e) }
        for g in bin.groups { deletePermanently(g) }
    }

    @discardableResult
    public func ensureRecycleBin() -> KPGroup {
        if let bin = recycleBin { return bin }
        let bin = KPGroup(name: "Recycle Bin")
        bin.iconID = 43
        bin.enableAutoType = false
        bin.enableSearching = false
        bin.isExpanded = false
        root.add(bin)
        meta.recycleBinUUID = bin.uuid
        meta.recycleBinChanged = Date.keepassNow
        return bin
    }

    /// Removes custom icons that are no longer referenced.
    public func pruneUnusedCustomIcons() {
        var used = Set<UUID>()
        for g in allGroups { if let u = g.customIconUUID { used.insert(u) } }
        for e in allEntries {
            if let u = e.customIconUUID { used.insert(u) }
            for h in e.history { if let u = h.customIconUUID { used.insert(u) } }
        }
        meta.customIcons.removeAll { !used.contains($0.uuid) }
    }

    /// All distinct tags used in the database, sorted.
    public var allTags: [String] {
        Array(Set(allEntries.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// The model is mutated only from the main actor in the apps; background work (saving,
// key derivation) operates on it while the UI waits, so it is safe to pass across tasks.
extension Database: @unchecked Sendable {}
