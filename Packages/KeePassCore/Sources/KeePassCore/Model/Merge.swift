// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// What a merge changed.
public struct MergeSummary: Equatable, Sendable {
    public var entriesAdded = 0
    public var entriesUpdated = 0
    public var entriesMoved = 0
    public var entriesDeleted = 0
    public var groupsAdded = 0
    public var groupsUpdated = 0
    public var groupsMoved = 0
    public var groupsDeleted = 0
    /// The database name, description, recycle bin, settings, icons or custom data changed.
    public var metadataChanged = false
    /// Older versions were added to entry histories (nothing visible changed).
    public var historyChanged = false

    public init() {}

    /// Entries and groups added, changed, moved or deleted.
    public var itemChanges: Int {
        entriesAdded + entriesUpdated + entriesMoved + entriesDeleted +
            groupsAdded + groupsUpdated + groupsMoved + groupsDeleted
    }

    public var isEmpty: Bool { itemChanges == 0 && !metadataChanged && !historyChanged }
}

extension Date {
    /// Whole seconds, the precision KeePass files store.
    var keepassSeconds: Int64 {
        let t = timeIntervalSince1970
        return t.isFinite ? Int64(max(min(t, 9.0e15), -9.0e15).rounded(.down)) : 0
    }
}

extension Database {
    /// Merges another copy of this database into this one, the way KeePassXC's "Merge from database"
    /// (KeePass "Synchronize") does:
    /// - entries and groups are matched by UUID, and the version with the newer modification time wins;
    ///   the older version of an entry is kept in its history;
    /// - an item's location follows the copy in which it was moved most recently;
    /// - items found only in `other` are added, items found only here are kept;
    /// - deletions recorded in either copy are applied, unless the item was changed after it was deleted;
    /// - custom icons are combined, and metadata follows its own "changed" times.
    ///
    /// Objects already in this database are updated in place, so references to them stay valid.
    /// Encryption settings follow the copy whose settings changed most recently;
    /// `preferOtherSettingsOnTie` decides when both changed at the same time.
    @discardableResult
    public func merge(from other: Database, preferOtherSettingsOnTie: Bool = false) -> MergeSummary {
        let merger = Merger(target: self, source: other)
        merger.run(preferOtherSettingsOnTie: preferOtherSettingsOnTie)
        return merger.summary
    }

    /// Makes this database identical to `other`, reusing the objects of entries and groups found in both
    /// (matched by UUID) so that references held elsewhere stay valid. Used to show the latest version
    /// of a file that is open read-only.
    public func adoptContent(of other: Database) {
        var groupIndex: [UUID: KPGroup] = [:]
        for g in allGroups where g !== root { groupIndex[g.uuid] = g }
        var entryIndex: [UUID: KPEntry] = [:]
        for e in allEntries { entryIndex[e.uuid] = e }

        func rebuild(_ source: KPGroup, into target: KPGroup) {
            var childGroups: [KPGroup] = []
            for sourceChild in source.groups {
                let child = groupIndex.removeValue(forKey: sourceChild.uuid) ?? KPGroup(uuid: sourceChild.uuid, name: sourceChild.name)
                child.takeProperties(from: sourceChild, includingLocation: true)
                childGroups.append(child)
                rebuild(sourceChild, into: child)
            }
            var childEntries: [KPEntry] = []
            for sourceEntry in source.entries {
                let entry = entryIndex.removeValue(forKey: sourceEntry.uuid) ?? KPEntry(uuid: sourceEntry.uuid)
                entry.takeEverything(from: sourceEntry)
                childEntries.append(entry)
            }
            target.replaceChildren(groups: childGroups, entries: childEntries)
        }

        root.uuid = other.root.uuid
        root.takeProperties(from: other.root, includingLocation: true)
        rebuild(other.root, into: root)
        meta = other.meta
        deletedObjects = other.deletedObjects
        settings = other.settings
        publicCustomData = other.publicCustomData
        transformCache = other.transformCache
    }

    /// A hash of what people see and edit: groups and entries with their placement, the icons they use,
    /// and the database name, description, default username and recycle bin. History, access times,
    /// the order of items, deletion records and encryption settings are left out, so two copies with the
    /// same fingerprint need no saving to bring them in line.
    public func contentFingerprint() -> Data {
        var out = Data()
        func put(_ s: String) {
            let bytes = Data(s.utf8)
            out.append(Data.le(UInt32(bytes.count)))
            out.append(bytes)
        }
        func put(_ date: Date) { put(String(date.keepassSeconds)) }
        func put(_ uuid: UUID?) { put(uuid?.uuidString ?? "-") }
        func put(_ flag: Bool?) { put(flag.map { $0 ? "1" : "0" } ?? "-") }
        func put(_ number: Int) { put(String(number)) }
        func putExpiry(_ times: Times) { put(times.expires); put(times.expires ? times.expiry : Date(timeIntervalSince1970: 0)) }

        put("meta")
        put(meta.databaseName)
        put(meta.databaseDescription)
        put(meta.defaultUserName)
        put(meta.recycleBinEnabled)
        put(meta.recycleBinUUID == .zero ? nil : meta.recycleBinUUID)

        let groups = allGroups.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        let entries = allEntries.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        var usedIcons = Set<UUID>()
        for g in groups {
            put("group")
            put(g.uuid)
            put(g.parent?.uuid)
            put(g.name)
            put(g.notes)
            put(g.iconID)
            put(g.customIconUUID)
            put(g.times.lastModification)
            putExpiry(g.times)
            put(g.enableSearching)
            put(g.enableAutoType)
            put(g.defaultAutoTypeSequence)
            put(g.tags.joined(separator: ";"))
            if let icon = g.customIconUUID { usedIcons.insert(icon) }
        }
        for e in entries {
            put("entry")
            put(e.uuid)
            put(e.parent?.uuid)
            // A missing standard field and an empty one mean the same.
            for f in e.fields.sorted(by: { $0.key < $1.key })
            where !(f.value.isEmpty && KPEntry.standardKeys.contains(f.key)) {
                put(f.key)
                put(f.value)
                put(f.isProtected)
            }
            for a in e.attachments.sorted(by: { $0.name < $1.name }) {
                put(a.name)
                put(Hash.sha256(a.data).hexString)
            }
            put(e.iconID)
            put(e.customIconUUID)
            put(e.foregroundColor)
            put(e.backgroundColor)
            put(e.overrideURL)
            put(e.tags.joined(separator: ";"))
            put(e.times.lastModification)
            putExpiry(e.times)
            if let icon = e.customIconUUID { usedIcons.insert(icon) }
        }
        for icon in meta.customIcons.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString })
        where usedIcons.contains(icon.uuid) {
            put("icon")
            put(icon.uuid)
            put(Hash.sha256(icon.data).hexString)
        }
        return Hash.sha256(out)
    }
}

/// Carries out `Database.merge(from:)`.
private final class Merger {
    let target: Database
    let source: Database
    var summary = MergeSummary()
    private var groups: [UUID: KPGroup] = [:]
    private var entries: [UUID: KPEntry] = [:]
    private let maxItems: Int
    private let maxSize: Int

    init(target: Database, source: Database) {
        self.target = target
        self.source = source
        maxItems = target.meta.historyMaxItems
        maxSize = target.meta.historyMaxSize
        for g in target.allGroups { groups[g.uuid] = g }
        for e in target.allEntries { entries[e.uuid] = e }
    }

    func run(preferOtherSettingsOnTie: Bool) {
        let root = target.root
        if source.root.uuid == root.uuid {
            if source.root.times.lastModification.keepassSeconds > root.times.lastModification.keepassSeconds {
                root.takeProperties(from: source.root, includingLocation: false)
                summary.groupsUpdated += 1
            }
        } else {
            // Copies made independently: treat the two root groups as the same group.
            groups[source.root.uuid] = root
        }
        mergeChildren(of: source.root, into: root)
        applyDeletions()
        mergeMetadata(preferOtherSettingsOnTie: preferOtherSettingsOnTie)
    }

    // MARK: Entries and groups

    private func mergeChildren(of sourceGroup: KPGroup, into targetGroup: KPGroup) {
        for sourceEntry in sourceGroup.entries {
            if let entry = entries[sourceEntry.uuid] {
                if sourceEntry.times.locationChanged.keepassSeconds > entry.times.locationChanged.keepassSeconds {
                    if entry.parent !== targetGroup {
                        targetGroup.add(entry)
                        summary.entriesMoved += 1
                    }
                    entry.times.locationChanged = sourceEntry.times.locationChanged
                    entry.previousParentGroup = sourceEntry.previousParentGroup
                }
                mergeEntry(sourceEntry, into: entry)
            } else {
                let copy = sourceEntry.copy(includeHistory: true)
                targetGroup.add(copy)
                entries[copy.uuid] = copy
                summary.entriesAdded += 1
            }
        }

        for sourceChild in sourceGroup.groups {
            let child: KPGroup
            if let existing = groups[sourceChild.uuid] {
                child = existing
                if existing !== target.root {
                    if sourceChild.times.locationChanged.keepassSeconds > existing.times.locationChanged.keepassSeconds,
                       targetGroup !== existing, !targetGroup.isDescendant(of: existing) {
                        if existing.parent !== targetGroup {
                            targetGroup.add(existing)
                            summary.groupsMoved += 1
                        }
                        existing.times.locationChanged = sourceChild.times.locationChanged
                        existing.previousParentGroup = sourceChild.previousParentGroup
                    }
                    if sourceChild.times.lastModification.keepassSeconds > existing.times.lastModification.keepassSeconds {
                        existing.takeProperties(from: sourceChild, includingLocation: false)
                        summary.groupsUpdated += 1
                    }
                }
            } else {
                child = sourceChild.copyWithoutChildren()
                targetGroup.add(child)
                groups[child.uuid] = child
                summary.groupsAdded += 1
            }
            mergeChildren(of: sourceChild, into: child)
        }
    }

    /// Keeps the newer version of the entry and puts the older one in its history.
    /// Histories are combined; versions with the same modification time count as the same version.
    private func mergeEntry(_ sourceEntry: KPEntry, into entry: KPEntry) {
        let sourceTime = sourceEntry.times.lastModification.keepassSeconds
        let targetTime = entry.times.lastModification.keepassSeconds
        let sourceIsNewer = sourceTime > targetTime
        let (newer, older) = sourceIsNewer ? (sourceEntry, entry) : (entry, sourceEntry)

        var byTime: [Int64: KPEntry] = [:]
        for item in newer.history { byTime[item.times.lastModification.keepassSeconds] = item }
        for item in older.history where byTime[item.times.lastModification.keepassSeconds] == nil {
            byTime[item.times.lastModification.keepassSeconds] = item
        }
        if sourceTime != targetTime {
            let olderTime = min(sourceTime, targetTime)
            if byTime[olderTime] == nil { byTime[olderTime] = older.copy(includeHistory: false) }
        }

        let oldHistory = entry.history
        let ours = Set(oldHistory.map(ObjectIdentifier.init))
        let history = byTime.keys.sorted().compactMap { byTime[$0] }.map { item -> KPEntry in
            // Versions from the other database are copied; this entry's own are reused.
            ours.contains(ObjectIdentifier(item)) ? item : item.copy(includeHistory: false)
        }

        if sourceIsNewer {
            entry.takeContent(from: sourceEntry)
            summary.entriesUpdated += 1
        }
        entry.history = history
        entry.truncateHistory(maxItems: maxItems, maxSize: maxSize)
        if !sourceIsNewer {
            let before = oldHistory.map { $0.times.lastModification.keepassSeconds }
            let after = entry.history.map { $0.times.lastModification.keepassSeconds }
            if before != after { summary.historyChanged = true }
        }
    }

    // MARK: Deletions

    /// Applies the deletions recorded in both copies. An item changed after it was deleted is kept,
    /// and so is a group that still holds items that were not deleted.
    private func applyDeletions() {
        var earliest: [UUID: DeletedObject] = [:]
        var order: [UUID] = []
        for record in target.deletedObjects + source.deletedObjects {
            if let known = earliest[record.uuid] {
                if record.deletionTime < known.deletionTime { earliest[record.uuid] = record }
            } else {
                earliest[record.uuid] = record
                order.append(record.uuid)
            }
        }

        var kept: [DeletedObject] = []
        var groupCandidates: [KPGroup] = []
        for uuid in order {
            guard let record = earliest[uuid] else { continue }
            if let entry = entries[uuid], entry.parent != nil {
                if entry.times.lastModification.keepassSeconds > record.deletionTime.keepassSeconds { continue }
                entry.parent?.remove(entry)
                entries[uuid] = nil
                summary.entriesDeleted += 1
                kept.append(record)
            } else if let group = groups[uuid], group !== target.root, group.parent != nil {
                groupCandidates.append(group)
            } else {
                kept.append(record)
            }
        }

        // Subgroups before the groups that contain them.
        func depth(_ g: KPGroup) -> Int {
            var n = 0
            var p = g.parent
            while let current = p { n += 1; p = current.parent }
            return n
        }
        groupCandidates.sort { depth($0) > depth($1) }
        for group in groupCandidates {
            guard let record = earliest[group.uuid] else { continue }
            if group.times.lastModification.keepassSeconds > record.deletionTime.keepassSeconds { continue }
            if !group.entries.isEmpty || !group.groups.isEmpty { continue }
            group.parent?.remove(group)
            groups[group.uuid] = nil
            summary.groupsDeleted += 1
            kept.append(record)
        }
        target.deletedObjects = kept
    }

    // MARK: Metadata

    private func mergeMetadata(preferOtherSettingsOnTie: Bool) {
        let mine = target.meta
        let theirs = source.meta
        var changed = false

        func newer(_ a: Date, than b: Date) -> Bool { a.keepassSeconds > b.keepassSeconds }

        if newer(theirs.databaseNameChanged, than: mine.databaseNameChanged) {
            changed = changed || mine.databaseName != theirs.databaseName
            mine.databaseName = theirs.databaseName
            mine.databaseNameChanged = theirs.databaseNameChanged
        }
        if newer(theirs.databaseDescriptionChanged, than: mine.databaseDescriptionChanged) {
            changed = changed || mine.databaseDescription != theirs.databaseDescription
            mine.databaseDescription = theirs.databaseDescription
            mine.databaseDescriptionChanged = theirs.databaseDescriptionChanged
        }
        if newer(theirs.defaultUserNameChanged, than: mine.defaultUserNameChanged) {
            changed = changed || mine.defaultUserName != theirs.defaultUserName
            mine.defaultUserName = theirs.defaultUserName
            mine.defaultUserNameChanged = theirs.defaultUserNameChanged
        }
        if newer(theirs.recycleBinChanged, than: mine.recycleBinChanged) {
            changed = changed || mine.recycleBinEnabled != theirs.recycleBinEnabled || mine.recycleBinUUID != theirs.recycleBinUUID
            mine.recycleBinEnabled = theirs.recycleBinEnabled
            mine.recycleBinUUID = theirs.recycleBinUUID
            mine.recycleBinChanged = theirs.recycleBinChanged
        }
        if newer(theirs.entryTemplatesGroupChanged, than: mine.entryTemplatesGroupChanged) {
            mine.entryTemplatesGroup = theirs.entryTemplatesGroup
            mine.entryTemplatesGroupChanged = theirs.entryTemplatesGroupChanged
        }
        if newer(theirs.masterKeyChanged, than: mine.masterKeyChanged) {
            mine.masterKeyChanged = theirs.masterKeyChanged
        }

        let mySettingsTime = mine.settingsChanged?.keepassSeconds ?? Int64.min
        let theirSettingsTime = theirs.settingsChanged?.keepassSeconds ?? Int64.min
        if theirSettingsTime > mySettingsTime || (theirSettingsTime == mySettingsTime && preferOtherSettingsOnTie) {
            changed = changed || mine.historyMaxItems != theirs.historyMaxItems || mine.historyMaxSize != theirs.historyMaxSize ||
                mine.memoryProtection != theirs.memoryProtection || mine.color != theirs.color ||
                target.settings != source.settings
            mine.maintenanceHistoryDays = theirs.maintenanceHistoryDays
            mine.color = theirs.color
            mine.masterKeyChangeRec = theirs.masterKeyChangeRec
            mine.masterKeyChangeForce = theirs.masterKeyChangeForce
            mine.masterKeyChangeForceOnce = theirs.masterKeyChangeForceOnce
            mine.memoryProtection = theirs.memoryProtection
            mine.historyMaxItems = theirs.historyMaxItems
            mine.historyMaxSize = theirs.historyMaxSize
            if let time = theirs.settingsChanged { mine.settingsChanged = time }
            target.settings = source.settings
            target.publicCustomData = source.publicCustomData
            if let cache = source.transformCache { target.transformCache = cache }
        }

        for icon in theirs.customIcons {
            if let i = mine.customIcons.firstIndex(where: { $0.uuid == icon.uuid }) {
                let a = mine.customIcons[i].lastModified?.keepassSeconds ?? Int64.min
                let b = icon.lastModified?.keepassSeconds ?? Int64.min
                if b > a && mine.customIcons[i] != icon {
                    mine.customIcons[i] = icon
                    changed = true
                }
            } else {
                mine.customIcons.append(icon)
                changed = true
            }
        }

        for item in theirs.customData {
            if let i = mine.customData.firstIndex(where: { $0.key == item.key }) {
                let a = mine.customData[i].lastModified?.keepassSeconds ?? Int64.min
                let b = item.lastModified?.keepassSeconds ?? Int64.min
                if b > a && mine.customData[i] != item {
                    mine.customData[i] = item
                    changed = true
                }
            } else {
                mine.customData.append(item)
                changed = true
            }
        }
        summary.metadataChanged = changed
    }
}
