// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public struct Times: Equatable {
    public var creation: Date
    public var lastModification: Date
    public var lastAccess: Date
    public var expiry: Date
    public var expires: Bool
    public var usageCount: Int
    public var locationChanged: Date

    public static func now() -> Times {
        let d = Date.keepassNow
        return Times(creation: d, lastModification: d, lastAccess: d, expiry: d, expires: false,
                     usageCount: 0, locationChanged: d)
    }

    public var isExpired: Bool { expires && expiry < Date() }

    public mutating func touch(modified: Bool) {
        let d = Date.keepassNow
        lastAccess = d
        if modified { lastModification = d }
    }
}

extension Date {
    /// KeePass stores times with one-second resolution.
    static var keepassNow: Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }
}

public struct EntryField: Equatable, Identifiable {
    public var key: String
    public var value: String
    public var isProtected: Bool
    public var id: String { key }

    public init(key: String, value: String, isProtected: Bool = false) {
        self.key = key; self.value = value; self.isProtected = isProtected
    }
}

public struct Attachment: Equatable, Identifiable {
    public var name: String
    public var data: Data
    public var isProtected: Bool
    public var id: String { name }

    public init(name: String, data: Data, isProtected: Bool = false) {
        self.name = name; self.data = data; self.isProtected = isProtected
    }
}

public struct CustomDataItem: Equatable {
    public var key: String
    public var value: String
    public var lastModified: Date?

    public init(key: String, value: String, lastModified: Date? = nil) {
        self.key = key; self.value = value; self.lastModified = lastModified
    }
}

public struct CustomIcon: Equatable, Identifiable {
    public var uuid: UUID
    public var data: Data
    public var name: String?
    public var lastModified: Date?
    public var id: UUID { uuid }

    public init(uuid: UUID = UUID(), data: Data, name: String? = nil, lastModified: Date? = nil) {
        self.uuid = uuid; self.data = data; self.name = name; self.lastModified = lastModified
    }
}

public struct DeletedObject: Equatable {
    public var uuid: UUID
    public var deletionTime: Date
}

public struct MemoryProtection: Equatable {
    public var protectTitle = false
    public var protectUserName = false
    public var protectPassword = true
    public var protectURL = false
    public var protectNotes = false

    public func shouldProtect(_ key: String) -> Bool {
        switch key {
        case KPEntry.titleKey: return protectTitle
        case KPEntry.userNameKey: return protectUserName
        case KPEntry.passwordKey: return protectPassword
        case KPEntry.urlKey: return protectURL
        case KPEntry.notesKey: return protectNotes
        default: return false
        }
    }
}

// MARK: - Entry

public final class KPEntry: Identifiable {
    public static let titleKey = "Title"
    public static let userNameKey = "UserName"
    public static let passwordKey = "Password"
    public static let urlKey = "URL"
    public static let notesKey = "Notes"
    public static let standardKeys: Set<String> = [titleKey, userNameKey, passwordKey, urlKey, notesKey]

    public var uuid: UUID
    public var iconID: Int = 0
    public var customIconUUID: UUID?
    public var foregroundColor = ""
    public var backgroundColor = ""
    public var overrideURL = ""
    public var tags: [String] = []
    public var qualityCheck: Bool?
    public var previousParentGroup: UUID?
    public var times = Times.now()
    public var fields: [EntryField] = []
    public var attachments: [Attachment] = []
    public var autoType: XNode?
    public var history: [KPEntry] = []
    public var customData: [CustomDataItem] = []
    public var unknownChildren: [XNode] = []
    public internal(set) weak var parent: KPGroup?

    public var id: UUID { uuid }

    public init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public func value(_ key: String) -> String { fields.first { $0.key == key }?.value ?? "" }
    public func field(_ key: String) -> EntryField? { fields.first { $0.key == key } }

    public func setValue(_ value: String, for key: String, protected: Bool? = nil) {
        if let i = fields.firstIndex(where: { $0.key == key }) {
            fields[i].value = value
            if let protected { fields[i].isProtected = protected }
        } else {
            fields.append(EntryField(key: key, value: value, isProtected: protected ?? false))
        }
    }

    public func removeField(_ key: String) { fields.removeAll { $0.key == key } }

    public var title: String { get { value(KPEntry.titleKey) } set { setValue(newValue, for: KPEntry.titleKey) } }
    public var userName: String { get { value(KPEntry.userNameKey) } set { setValue(newValue, for: KPEntry.userNameKey) } }
    public var password: String { get { value(KPEntry.passwordKey) } set { setValue(newValue, for: KPEntry.passwordKey) } }
    public var url: String { get { value(KPEntry.urlKey) } set { setValue(newValue, for: KPEntry.urlKey) } }
    public var notes: String { get { value(KPEntry.notesKey) } set { setValue(newValue, for: KPEntry.notesKey) } }

    /// Fields other than the five standard ones, in file order.
    public var customFields: [EntryField] { fields.filter { !KPEntry.standardKeys.contains($0.key) } }

    /// Deep copy keeping the same UUID. History entries are copied too unless `includeHistory` is false.
    public func copy(includeHistory: Bool = true) -> KPEntry {
        let e = KPEntry(uuid: uuid)
        e.iconID = iconID
        e.customIconUUID = customIconUUID
        e.foregroundColor = foregroundColor
        e.backgroundColor = backgroundColor
        e.overrideURL = overrideURL
        e.tags = tags
        e.qualityCheck = qualityCheck
        e.previousParentGroup = previousParentGroup
        e.times = times
        e.fields = fields
        e.attachments = attachments
        e.autoType = autoType?.deepCopy()
        e.history = includeHistory ? history.map { $0.copy(includeHistory: false) } : []
        e.customData = customData
        e.unknownChildren = unknownChildren.map { $0.deepCopy() }
        return e
    }

    /// Records the current state in the history, trimming to `maxItems` (negative = unlimited).
    public func backupToHistory(maxItems: Int, maxSize: Int = -1) {
        history.append(copy(includeHistory: false))
        truncateHistory(maxItems: maxItems, maxSize: maxSize)
    }

    /// Drops the oldest history items beyond `maxItems` versions or `maxSize` bytes (negative = unlimited).
    public func truncateHistory(maxItems: Int, maxSize: Int = -1) {
        if maxItems >= 0 {
            while history.count > maxItems { history.removeFirst() }
        }
        if maxSize >= 0 {
            while !history.isEmpty && history.reduce(0, { $0 + $1.approximateSize }) > maxSize {
                history.removeFirst()
            }
        }
    }

    /// Takes the content and times of another version of this entry (used when merging).
    /// The location (group, `locationChanged`, `previousParentGroup`) and the history are left alone;
    /// last access and usage count keep the larger value.
    func takeContent(from other: KPEntry) {
        iconID = other.iconID
        customIconUUID = other.customIconUUID
        foregroundColor = other.foregroundColor
        backgroundColor = other.backgroundColor
        overrideURL = other.overrideURL
        tags = other.tags
        qualityCheck = other.qualityCheck
        fields = other.fields
        attachments = other.attachments
        autoType = other.autoType?.deepCopy()
        customData = other.customData
        unknownChildren = other.unknownChildren.map { $0.deepCopy() }
        times.creation = other.times.creation
        times.lastModification = other.times.lastModification
        times.expiry = other.times.expiry
        times.expires = other.times.expires
        times.lastAccess = max(times.lastAccess, other.times.lastAccess)
        times.usageCount = max(times.usageCount, other.times.usageCount)
    }

    /// Becomes an exact copy of `other` (same content, times and history), keeping only its own identity.
    func takeEverything(from other: KPEntry) {
        takeContent(from: other)
        times = other.times
        previousParentGroup = other.previousParentGroup
        history = other.history.map { $0.copy(includeHistory: false) }
    }

    var approximateSize: Int {
        fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } +
            attachments.reduce(0) { $0 + $1.data.count } + 128
    }

    /// Copies the content (not identity, parent or history) from another entry.
    public func restore(from other: KPEntry) {
        iconID = other.iconID
        customIconUUID = other.customIconUUID
        foregroundColor = other.foregroundColor
        backgroundColor = other.backgroundColor
        overrideURL = other.overrideURL
        tags = other.tags
        fields = other.fields
        attachments = other.attachments
        autoType = other.autoType?.deepCopy()
        customData = other.customData
        times.expires = other.times.expires
        times.expiry = other.times.expiry
        times.touch(modified: true)
    }

    public var path: String {
        var parts: [String] = []
        var g = parent
        while let group = g, group.parent != nil {
            parts.insert(group.name, at: 0)
            g = group.parent
        }
        return parts.joined(separator: " / ")
    }
}

// MARK: - Group

public final class KPGroup: Identifiable {
    public var uuid: UUID
    public var name: String
    public var notes = ""
    public var iconID: Int = 48
    public var customIconUUID: UUID?
    public var times = Times.now()
    public var isExpanded = true
    public var defaultAutoTypeSequence = ""
    public var enableAutoType: Bool?
    public var enableSearching: Bool?
    public var lastTopVisibleEntry = UUID.zero
    public var tags: [String] = []
    public var previousParentGroup: UUID?
    public var customData: [CustomDataItem] = []
    public var unknownChildren: [XNode] = []
    public private(set) var groups: [KPGroup] = []
    public private(set) var entries: [KPEntry] = []
    public internal(set) weak var parent: KPGroup?

    public var id: UUID { uuid }

    public init(uuid: UUID = UUID(), name: String) {
        self.uuid = uuid
        self.name = name
    }

    public func add(_ entry: KPEntry) {
        entry.parent?.remove(entry)
        entry.parent = self
        entries.append(entry)
    }

    public func add(_ group: KPGroup) {
        group.parent?.remove(group)
        group.parent = self
        groups.append(group)
    }

    public func remove(_ entry: KPEntry) {
        entries.removeAll { $0 === entry }
        if entry.parent === self { entry.parent = nil }
    }

    public func remove(_ group: KPGroup) {
        groups.removeAll { $0 === group }
        if group.parent === self { group.parent = nil }
    }

    public func sortChildren(by areInIncreasingOrder: (KPEntry, KPEntry) -> Bool) {
        entries.sort(by: areInIncreasingOrder)
    }

    /// Replaces the children in one go (used when mirroring another copy of the database).
    /// Former children that were not moved elsewhere are detached.
    func replaceChildren(groups newGroups: [KPGroup], entries newEntries: [KPEntry]) {
        let keptGroups = Set(newGroups.map(ObjectIdentifier.init))
        let keptEntries = Set(newEntries.map(ObjectIdentifier.init))
        for g in groups where g.parent === self && !keptGroups.contains(ObjectIdentifier(g)) { g.parent = nil }
        for e in entries where e.parent === self && !keptEntries.contains(ObjectIdentifier(e)) { e.parent = nil }
        groups = newGroups
        entries = newEntries
        for g in newGroups { g.parent = self }
        for e in newEntries { e.parent = self }
    }

    /// Takes the name, notes, icon, times and settings of another version of this group (used when merging).
    /// With `includingLocation` the location fields and the expanded state are copied too.
    func takeProperties(from other: KPGroup, includingLocation: Bool) {
        name = other.name
        notes = other.notes
        iconID = other.iconID
        customIconUUID = other.customIconUUID
        defaultAutoTypeSequence = other.defaultAutoTypeSequence
        enableAutoType = other.enableAutoType
        enableSearching = other.enableSearching
        tags = other.tags
        customData = other.customData
        unknownChildren = other.unknownChildren.map { $0.deepCopy() }
        if includingLocation {
            times = other.times
            previousParentGroup = other.previousParentGroup
            isExpanded = other.isExpanded
            lastTopVisibleEntry = other.lastTopVisibleEntry
        } else {
            let location = times.locationChanged
            let lastAccess = max(times.lastAccess, other.times.lastAccess)
            let usage = max(times.usageCount, other.times.usageCount)
            times = other.times
            times.locationChanged = location
            times.lastAccess = lastAccess
            times.usageCount = usage
        }
    }

    /// A copy of this group's own properties (same UUID) without entries or subgroups.
    func copyWithoutChildren() -> KPGroup {
        let g = KPGroup(uuid: uuid, name: name)
        g.takeProperties(from: self, includingLocation: true)
        return g
    }

    /// All entries in this group and its descendants.
    public var allEntries: [KPEntry] {
        var result = entries
        for g in groups { result += g.allEntries }
        return result
    }

    public var allGroups: [KPGroup] {
        var result: [KPGroup] = []
        for g in groups { result.append(g); result += g.allGroups }
        return result
    }

    public func isDescendant(of other: KPGroup) -> Bool {
        var g = parent
        while let current = g {
            if current === other { return true }
            g = current.parent
        }
        return false
    }

    public var isSearchable: Bool {
        if let enableSearching { return enableSearching }
        return parent?.isSearchable ?? true
    }

    public var path: String {
        var parts: [String] = [name]
        var g = parent
        while let group = g, group.parent != nil {
            parts.insert(group.name, at: 0)
            g = group.parent
        }
        return parts.joined(separator: " / ")
    }
}

// MARK: - Meta

public final class Meta {
    public var generator = "SaveKey"
    public var settingsChanged: Date?
    public var databaseName = ""
    public var databaseNameChanged = Date.keepassNow
    public var databaseDescription = ""
    public var databaseDescriptionChanged = Date.keepassNow
    public var defaultUserName = ""
    public var defaultUserNameChanged = Date.keepassNow
    public var maintenanceHistoryDays = 365
    public var color = ""
    public var masterKeyChanged = Date.keepassNow
    public var masterKeyChangeRec: Int64 = -1
    public var masterKeyChangeForce: Int64 = -1
    public var masterKeyChangeForceOnce = false
    public var memoryProtection = MemoryProtection()
    public var customIcons: [CustomIcon] = []
    public var recycleBinEnabled = true
    public var recycleBinUUID = UUID.zero
    public var recycleBinChanged = Date.keepassNow
    public var entryTemplatesGroup = UUID.zero
    public var entryTemplatesGroupChanged = Date.keepassNow
    public var historyMaxItems = 10
    public var historyMaxSize = 6 * 1024 * 1024
    public var lastSelectedGroup = UUID.zero
    public var lastTopVisibleGroup = UUID.zero
    public var customData: [CustomDataItem] = []
    public var unknownChildren: [XNode] = []

    public init() {}

    public func customIcon(_ uuid: UUID?) -> CustomIcon? {
        guard let uuid else { return nil }
        return customIcons.first { $0.uuid == uuid }
    }
}

public struct DatabaseSettings: Equatable {
    public var formatVersion: UInt32
    public var cipher: Cipher
    public var compression: Bool
    public var kdf: KDFParameters

    public init(formatVersion: UInt32 = KDBX.version40, cipher: Cipher = .aes256, compression: Bool = true,
                kdf: KDFParameters = .defaultArgon2id()) {
        self.formatVersion = formatVersion; self.cipher = cipher; self.compression = compression; self.kdf = kdf
    }

    public var versionString: String {
        "KDBX \(formatVersion >> 16).\(formatVersion & 0xFFFF)"
    }
}

extension KPEntry: @unchecked Sendable {}
extension KPGroup: @unchecked Sendable {}
extension Meta: @unchecked Sendable {}
