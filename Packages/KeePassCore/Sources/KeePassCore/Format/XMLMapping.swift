// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Converts between the KeePass XML document and the object model.
enum XMLMapping {
    // MARK: - Value helpers

    static let epochOffset: Int64 = 62_135_596_800 // seconds between 0001-01-01 and 1970-01-01

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("-") && t.contains(":") {
            return isoFormatter.date(from: t) ?? isoFractionalFormatter.date(from: t) ??
                isoFormatter.date(from: t + "Z") ?? isoFractionalFormatter.date(from: t + "Z")
        }
        guard let d = Data(base64Encoded: t), d.count == 8 else { return nil }
        var r = ByteReader(d)
        guard let raw = try? r.u64() else { return nil }
        let seconds = Int64(bitPattern: raw)
        return Date(timeIntervalSince1970: TimeInterval(seconds - epochOffset))
    }

    static func formatDate(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        let seconds: Int64 = t.isFinite ? Int64(max(min(t, 253_402_300_799), -62_135_596_800).rounded(.down)) + epochOffset : epochOffset
        return Data.le(UInt64(bitPattern: seconds)).base64EncodedString()
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    static func boolString(_ b: Bool) -> String { b ? "True" : "False" }
    static func nullableBoolString(_ b: Bool?) -> String { b.map(boolString) ?? "null" }

    static func parseUUID(_ node: XNode?) -> UUID? {
        guard let node, let u = UUID(keepassBase64: node.text) else { return nil }
        return u
    }

    static func nonZero(_ u: UUID?) -> UUID? { u == .zero ? nil : u }

    static func parseTags(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reading

    struct ReadContext {
        var binaries: [Int: Attachment] // name is unused here; data + protected flag
    }

    static func read(document root: XNode, binaries: [Int: Attachment], into db: Database) throws {
        guard root.name == "KeePassFile" else { throw KDBXError.xmlParseFailure("missing KeePassFile element") }
        var ctx = ReadContext(binaries: binaries)
        if let metaNode = root.child("Meta") {
            db.meta = parseMeta(metaNode, ctx: &ctx)
        }
        guard let rootNode = root.child("Root"), let groupNode = rootNode.child("Group") else {
            throw KDBXError.xmlParseFailure("missing root group")
        }
        db.root = parseGroup(groupNode, ctx: ctx)
        if let deleted = rootNode.child("DeletedObjects") {
            db.deletedObjects = deleted.children("DeletedObject").compactMap { d in
                guard let u = parseUUID(d.child("UUID")) else { return nil }
                return DeletedObject(uuid: u, deletionTime: parseDate(d.child("DeletionTime")?.text ?? "") ?? Date())
            }
        }
    }

    static func parseTimes(_ n: XNode) -> Times {
        var t = Times.now()
        for c in n.children {
            switch c.name {
            case "CreationTime": t.creation = parseDate(c.text) ?? t.creation
            case "LastModificationTime": t.lastModification = parseDate(c.text) ?? t.lastModification
            case "LastAccessTime": t.lastAccess = parseDate(c.text) ?? t.lastAccess
            case "ExpiryTime": t.expiry = parseDate(c.text) ?? t.expiry
            case "Expires": t.expires = parseBool(c.text) ?? false
            case "UsageCount": t.usageCount = Int(c.text.trimmingCharacters(in: .whitespaces)) ?? 0
            case "LocationChanged": t.locationChanged = parseDate(c.text) ?? t.locationChanged
            default: break
            }
        }
        return t
    }

    static func parseCustomData(_ n: XNode) -> [CustomDataItem] {
        n.children("Item").compactMap { item in
            guard let key = item.child("Key")?.text else { return nil }
            return CustomDataItem(key: key, value: item.child("Value")?.text ?? "",
                                  lastModified: item.child("LastModificationTime").flatMap { parseDate($0.text) })
        }
    }

    static func parseMeta(_ n: XNode, ctx: inout ReadContext) -> Meta {
        let m = Meta()
        for c in n.children {
            let text = c.text
            switch c.name {
            case "Generator": m.generator = text
            case "HeaderHash": break // KDBX 3 only; recomputed formats don't need it
            case "SettingsChanged": m.settingsChanged = parseDate(text)
            case "DatabaseName": m.databaseName = text
            case "DatabaseNameChanged": m.databaseNameChanged = parseDate(text) ?? m.databaseNameChanged
            case "DatabaseDescription": m.databaseDescription = text
            case "DatabaseDescriptionChanged": m.databaseDescriptionChanged = parseDate(text) ?? m.databaseDescriptionChanged
            case "DefaultUserName": m.defaultUserName = text
            case "DefaultUserNameChanged": m.defaultUserNameChanged = parseDate(text) ?? m.defaultUserNameChanged
            case "MaintenanceHistoryDays": m.maintenanceHistoryDays = Int(text) ?? 365
            case "Color": m.color = text
            case "MasterKeyChanged": m.masterKeyChanged = parseDate(text) ?? m.masterKeyChanged
            case "MasterKeyChangeRec": m.masterKeyChangeRec = Int64(text) ?? -1
            case "MasterKeyChangeForce": m.masterKeyChangeForce = Int64(text) ?? -1
            case "MasterKeyChangeForceOnce": m.masterKeyChangeForceOnce = parseBool(text) ?? false
            case "MemoryProtection":
                for p in c.children {
                    let v = parseBool(p.text) ?? false
                    switch p.name {
                    case "ProtectTitle": m.memoryProtection.protectTitle = v
                    case "ProtectUserName": m.memoryProtection.protectUserName = v
                    case "ProtectPassword": m.memoryProtection.protectPassword = v
                    case "ProtectURL": m.memoryProtection.protectURL = v
                    case "ProtectNotes": m.memoryProtection.protectNotes = v
                    default: break
                    }
                }
            case "CustomIcons":
                m.customIcons = c.children("Icon").compactMap { icon in
                    guard let u = parseUUID(icon.child("UUID")),
                          let d = Data(base64Encoded: icon.child("Data")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    else { return nil }
                    return CustomIcon(uuid: u, data: d, name: icon.child("Name")?.text,
                                      lastModified: icon.child("LastModificationTime").flatMap { parseDate($0.text) })
                }
            case "RecycleBinEnabled": m.recycleBinEnabled = parseBool(text) ?? true
            case "RecycleBinUUID": m.recycleBinUUID = parseUUID(c) ?? .zero
            case "RecycleBinChanged": m.recycleBinChanged = parseDate(text) ?? m.recycleBinChanged
            case "EntryTemplatesGroup": m.entryTemplatesGroup = parseUUID(c) ?? .zero
            case "EntryTemplatesGroupChanged": m.entryTemplatesGroupChanged = parseDate(text) ?? m.entryTemplatesGroupChanged
            case "HistoryMaxItems": m.historyMaxItems = Int(text) ?? 10
            case "HistoryMaxSize": m.historyMaxSize = Int(text) ?? 6 * 1024 * 1024
            case "LastSelectedGroup": m.lastSelectedGroup = parseUUID(c) ?? .zero
            case "LastTopVisibleGroup": m.lastTopVisibleGroup = parseUUID(c) ?? .zero
            case "Binaries": // KDBX 3.1 binary pool
                for b in c.children("Binary") {
                    guard let idText = b.attribute("ID"), let id = Int(idText),
                          var data = Data(base64Encoded: b.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    else { continue }
                    if parseBool(b.attribute("Compressed") ?? "") == true, let unzipped = try? Gzip.decompress(data) {
                        data = unzipped
                    }
                    ctx.binaries[id] = Attachment(name: "", data: data, isProtected: parseBool(b.attribute("Protected") ?? "") == true)
                }
            case "CustomData": m.customData = parseCustomData(c)
            default: m.unknownChildren.append(c)
            }
        }
        return m
    }

    static func parseGroup(_ n: XNode, ctx: ReadContext) -> KPGroup {
        let g = KPGroup(uuid: parseUUID(n.child("UUID")) ?? UUID(), name: "")
        for c in n.children {
            switch c.name {
            case "UUID": break
            case "Name": g.name = c.text
            case "Notes": g.notes = c.text
            case "IconID": g.iconID = Int(c.text.trimmingCharacters(in: .whitespaces)) ?? 48
            case "CustomIconUUID": g.customIconUUID = nonZero(parseUUID(c))
            case "Times": g.times = parseTimes(c)
            case "IsExpanded": g.isExpanded = parseBool(c.text) ?? true
            case "DefaultAutoTypeSequence": g.defaultAutoTypeSequence = c.text
            case "EnableAutoType": g.enableAutoType = parseBool(c.text)
            case "EnableSearching": g.enableSearching = parseBool(c.text)
            case "LastTopVisibleEntry": g.lastTopVisibleEntry = parseUUID(c) ?? .zero
            case "Tags": g.tags = parseTags(c.text)
            case "PreviousParentGroup": g.previousParentGroup = nonZero(parseUUID(c))
            case "CustomData": g.customData = parseCustomData(c)
            case "Entry": g.add(parseEntry(c, ctx: ctx, isHistory: false))
            case "Group": g.add(parseGroup(c, ctx: ctx))
            default: g.unknownChildren.append(c)
            }
        }
        return g
    }

    static func parseEntry(_ n: XNode, ctx: ReadContext, isHistory: Bool) -> KPEntry {
        let e = KPEntry(uuid: parseUUID(n.child("UUID")) ?? UUID())
        for c in n.children {
            switch c.name {
            case "UUID": break
            case "IconID": e.iconID = Int(c.text.trimmingCharacters(in: .whitespaces)) ?? 0
            case "CustomIconUUID": e.customIconUUID = nonZero(parseUUID(c))
            case "ForegroundColor": e.foregroundColor = c.text
            case "BackgroundColor": e.backgroundColor = c.text
            case "OverrideURL": e.overrideURL = c.text
            case "Tags": e.tags = parseTags(c.text)
            case "QualityCheck": e.qualityCheck = parseBool(c.text)
            case "PreviousParentGroup": e.previousParentGroup = nonZero(parseUUID(c))
            case "Times": e.times = parseTimes(c)
            case "String":
                guard let key = c.child("Key")?.text else { continue }
                let valueNode = c.child("Value")
                let protected = parseBool(valueNode?.attribute("Protected") ?? "") == true ||
                    parseBool(valueNode?.attribute("ProtectInMemory") ?? "") == true
                e.fields.append(EntryField(key: key, value: valueNode?.text ?? "", isProtected: protected))
            case "Binary":
                guard let key = c.child("Key")?.text, let valueNode = c.child("Value") else { continue }
                if let ref = valueNode.attribute("Ref"), let idx = Int(ref), let bin = ctx.binaries[idx] {
                    e.attachments.append(Attachment(name: key, data: bin.data, isProtected: bin.isProtected))
                } else if let inline = Data(base64Encoded: valueNode.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    e.attachments.append(Attachment(name: key, data: inline))
                }
            case "AutoType": e.autoType = c
            case "History":
                if !isHistory {
                    e.history = c.children("Entry").map { parseEntry($0, ctx: ctx, isHistory: true) }
                }
            case "CustomData": e.customData = parseCustomData(c)
            default: e.unknownChildren.append(c)
            }
        }
        return e
    }

    // MARK: - Writing

    final class BinaryPool {
        private(set) var items: [Attachment] = []
        private var index: [Data: Int] = [:]

        func ref(for a: Attachment) -> Int {
            if let i = index[a.data] {
                if a.isProtected { items[i].isProtected = true }
                return i
            }
            items.append(Attachment(name: "", data: a.data, isProtected: a.isProtected))
            index[a.data] = items.count - 1
            return items.count - 1
        }
    }

    static func needsVersion41(_ db: Database) -> Bool {
        if db.meta.customIcons.contains(where: { $0.name != nil || $0.lastModified != nil }) { return true }
        if db.meta.customData.contains(where: { $0.lastModified != nil }) { return true }
        for g in db.allGroups where !g.tags.isEmpty || g.previousParentGroup != nil { return true }
        for e in db.allEntries where e.qualityCheck != nil || e.previousParentGroup != nil { return true }
        return false
    }

    static func buildDocument(_ db: Database, pool: BinaryPool, v41: Bool) -> XNode {
        // Collect attachments first so refs are stable.
        for e in db.allEntries {
            for a in e.attachments { _ = pool.ref(for: a) }
            for h in e.history { for a in h.attachments { _ = pool.ref(for: a) } }
        }
        let root = XNode("KeePassFile")
        root.add(writeMeta(db.meta, v41: v41))
        let rootNode = XNode("Root")
        rootNode.add(writeGroup(db.root, pool: pool, v41: v41))
        let deleted = XNode("DeletedObjects")
        for d in db.deletedObjects {
            let n = XNode("DeletedObject")
            n.add("UUID", d.uuid.keepassBase64)
            n.add("DeletionTime", formatDate(d.deletionTime))
            deleted.add(n)
        }
        rootNode.add(deleted)
        root.add(rootNode)
        return root
    }

    static func writeTimes(_ t: Times) -> XNode {
        let n = XNode("Times")
        n.add("CreationTime", formatDate(t.creation))
        n.add("LastModificationTime", formatDate(t.lastModification))
        n.add("LastAccessTime", formatDate(t.lastAccess))
        n.add("ExpiryTime", formatDate(t.expiry))
        n.add("Expires", boolString(t.expires))
        n.add("UsageCount", String(t.usageCount))
        n.add("LocationChanged", formatDate(t.locationChanged))
        return n
    }

    static func writeCustomData(_ items: [CustomDataItem], v41: Bool) -> XNode? {
        guard !items.isEmpty else { return nil }
        let n = XNode("CustomData")
        for item in items {
            let i = XNode("Item")
            i.add("Key", item.key)
            i.add("Value", item.value)
            if v41, let lm = item.lastModified { i.add("LastModificationTime", formatDate(lm)) }
            n.add(i)
        }
        return n
    }

    static func writeMeta(_ m: Meta, v41: Bool) -> XNode {
        let n = XNode("Meta")
        n.add("Generator", "SaveKey")
        if let sc = m.settingsChanged { n.add("SettingsChanged", formatDate(sc)) }
        n.add("DatabaseName", m.databaseName)
        n.add("DatabaseNameChanged", formatDate(m.databaseNameChanged))
        n.add("DatabaseDescription", m.databaseDescription)
        n.add("DatabaseDescriptionChanged", formatDate(m.databaseDescriptionChanged))
        n.add("DefaultUserName", m.defaultUserName)
        n.add("DefaultUserNameChanged", formatDate(m.defaultUserNameChanged))
        n.add("MaintenanceHistoryDays", String(m.maintenanceHistoryDays))
        n.add("Color", m.color)
        n.add("MasterKeyChanged", formatDate(m.masterKeyChanged))
        n.add("MasterKeyChangeRec", String(m.masterKeyChangeRec))
        n.add("MasterKeyChangeForce", String(m.masterKeyChangeForce))
        if m.masterKeyChangeForceOnce { n.add("MasterKeyChangeForceOnce", "True") }
        let mp = XNode("MemoryProtection")
        mp.add("ProtectTitle", boolString(m.memoryProtection.protectTitle))
        mp.add("ProtectUserName", boolString(m.memoryProtection.protectUserName))
        mp.add("ProtectPassword", boolString(m.memoryProtection.protectPassword))
        mp.add("ProtectURL", boolString(m.memoryProtection.protectURL))
        mp.add("ProtectNotes", boolString(m.memoryProtection.protectNotes))
        n.add(mp)
        if !m.customIcons.isEmpty {
            let icons = XNode("CustomIcons")
            for icon in m.customIcons {
                let i = XNode("Icon")
                i.add("UUID", icon.uuid.keepassBase64)
                i.add("Data", icon.data.base64EncodedString())
                if v41, let name = icon.name { i.add("Name", name) }
                if v41, let lm = icon.lastModified { i.add("LastModificationTime", formatDate(lm)) }
                icons.add(i)
            }
            n.add(icons)
        }
        n.add("RecycleBinEnabled", boolString(m.recycleBinEnabled))
        n.add("RecycleBinUUID", m.recycleBinUUID.keepassBase64)
        n.add("RecycleBinChanged", formatDate(m.recycleBinChanged))
        n.add("EntryTemplatesGroup", m.entryTemplatesGroup.keepassBase64)
        n.add("EntryTemplatesGroupChanged", formatDate(m.entryTemplatesGroupChanged))
        n.add("HistoryMaxItems", String(m.historyMaxItems))
        n.add("HistoryMaxSize", String(m.historyMaxSize))
        n.add("LastSelectedGroup", m.lastSelectedGroup.keepassBase64)
        n.add("LastTopVisibleGroup", m.lastTopVisibleGroup.keepassBase64)
        if let cd = writeCustomData(m.customData, v41: v41) { n.add(cd) }
        m.unknownChildren.forEach { n.add($0) }
        return n
    }

    static func writeGroup(_ g: KPGroup, pool: BinaryPool, v41: Bool) -> XNode {
        let n = XNode("Group")
        n.add("UUID", g.uuid.keepassBase64)
        n.add("Name", g.name)
        n.add("Notes", g.notes)
        n.add("IconID", String(g.iconID))
        if let ci = g.customIconUUID { n.add("CustomIconUUID", ci.keepassBase64) }
        n.add(writeTimes(g.times))
        n.add("IsExpanded", boolString(g.isExpanded))
        n.add("DefaultAutoTypeSequence", g.defaultAutoTypeSequence)
        n.add("EnableAutoType", nullableBoolString(g.enableAutoType))
        n.add("EnableSearching", nullableBoolString(g.enableSearching))
        n.add("LastTopVisibleEntry", g.lastTopVisibleEntry.keepassBase64)
        if v41 {
            if let p = g.previousParentGroup { n.add("PreviousParentGroup", p.keepassBase64) }
            if !g.tags.isEmpty { n.add("Tags", g.tags.joined(separator: ";")) }
        }
        if let cd = writeCustomData(g.customData, v41: v41) { n.add(cd) }
        g.unknownChildren.forEach { n.add($0) }
        for e in g.entries { n.add(writeEntry(e, pool: pool, v41: v41, isHistory: false)) }
        for child in g.groups { n.add(writeGroup(child, pool: pool, v41: v41)) }
        return n
    }

    static func writeEntry(_ e: KPEntry, pool: BinaryPool, v41: Bool, isHistory: Bool) -> XNode {
        let n = XNode("Entry")
        n.add("UUID", e.uuid.keepassBase64)
        n.add("IconID", String(e.iconID))
        if let ci = e.customIconUUID { n.add("CustomIconUUID", ci.keepassBase64) }
        n.add("ForegroundColor", e.foregroundColor)
        n.add("BackgroundColor", e.backgroundColor)
        n.add("OverrideURL", e.overrideURL)
        if v41, let qc = e.qualityCheck { n.add("QualityCheck", boolString(qc)) }
        n.add("Tags", e.tags.joined(separator: ";"))
        if v41, let p = e.previousParentGroup { n.add("PreviousParentGroup", p.keepassBase64) }
        n.add(writeTimes(e.times))
        for f in e.fields {
            let s = XNode("String")
            s.add("Key", f.key)
            let v = XNode("Value", text: f.value)
            if f.isProtected { v.setAttribute("Protected", "True") }
            s.add(v)
            n.add(s)
        }
        for a in e.attachments {
            let b = XNode("Binary")
            b.add("Key", a.name)
            b.add(XNode("Value", attributes: [("Ref", String(pool.ref(for: a)))]))
            n.add(b)
        }
        if let at = e.autoType {
            n.add(at.deepCopy())
        } else {
            let at = XNode("AutoType")
            at.add("Enabled", "True")
            at.add("DataTransferObfuscation", "0")
            n.add(at)
        }
        if let cd = writeCustomData(e.customData, v41: v41) { n.add(cd) }
        e.unknownChildren.forEach { n.add($0) }
        if !isHistory {
            let h = XNode("History")
            for old in e.history { h.add(writeEntry(old, pool: pool, v41: v41, isHistory: true)) }
            n.add(h)
        }
        return n
    }
}
