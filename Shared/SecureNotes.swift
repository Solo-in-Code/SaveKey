// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import KeePassCore

/// The folder for secure notes. Entries in it (or in its subfolders) are notes: they are edited and
/// shown without the credentials and one-time password sections. Those still appear for an entry that
/// already has a username, password, URL or one-time password, so nothing is ever hidden.
enum NotesFolder {
    /// Folder names recognised as the Notes folder, in all of SaveKey's languages.
    static let names: Set<String> = [
        "notes", "note", "secure notes", "secure note", "notas", "nota", "notas seguras",
        "notizen", "notiz", "sichere notizen", "note sicure", "notes sécurisées",
    ]
    /// Name given to the folder when SaveKey creates it, in the app's language.
    static var defaultName: String { String(localized: "Notes") }
    /// Standard KeePass icon 7 (Notepad), used for the folder and for new notes.
    static let iconID = 7

    static func find(in db: Database) -> KPGroup? {
        let own = defaultName.lowercased()
        return db.root.groups.first {
            let name = $0.name.trimmingCharacters(in: .whitespaces).lowercased()
            return (names.contains(name) || name == own) && !db.isInRecycleBin($0)
        }
    }

    static func findOrCreate(in db: Database) -> KPGroup {
        if let existing = find(in: db) { return existing }
        let group = db.createGroup(named: defaultName, in: db.root)
        group.iconID = iconID
        return group
    }

    /// True if `group` is the Notes folder or inside it.
    static func contains(_ group: KPGroup, in db: Database) -> Bool {
        guard let notes = find(in: db) else { return false }
        return group === notes || group.isDescendant(of: notes)
    }

    /// True if the entry is stored in the Notes folder. Pass the owning entry for history versions.
    static func contains(_ entry: KPEntry, in db: Database) -> Bool {
        guard let parent = entry.parent else { return false }
        return contains(parent, in: db)
    }
}

extension KPEntry {
    /// True if the entry has anything to sign in with: username, password, URL or one-time password.
    var hasCredentials: Bool {
        !userName.isEmpty || !password.isEmpty || !url.isEmpty || OTPConfig.from(entry: self) != nil
    }
}
