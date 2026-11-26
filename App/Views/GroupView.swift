// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

/// Root container for an unlocked database: navigation, watching the file, and save/conflict alerts.
struct DatabaseBrowserView: View {
    @EnvironmentObject private var session: DatabaseSession
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: DatabaseLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false
    @State private var folderError: String?

    var body: some View {
        NavigationStack {
            GroupView(group: session.database.root, isRoot: true, onChooseFolder: { choosingFolder = true })
        }
        .onAppear { session.startWatching() }
        .onDisappear { session.stopWatching() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { session.startWatching() } else { session.stopWatching() }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { follow(in: folder) }
        }
        .alert("Save failed", isPresented: Binding(get: { session.saveError != nil },
                                                   set: { if !$0 { session.saveError = nil } })) {
            if session.needsFolder {
                Button("Choose folder…") { chooseFolderAfterAlert() }
            }
            Button("Retry") { Task { await session.save() } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.saveError ?? "")
        }
        .alert("Database changed elsewhere", isPresented: Binding(get: { session.conflict != nil },
                                                                  set: { if !$0 { session.conflict = nil } }),
               presenting: session.conflict) { conflict in
            switch conflict {
            case .differentKey:
                Button("Lock") { appState.lock() }
            case .unreadable:
                Button("Try again") { Task { await session.tryAgainAfterConflict() } }
            }
            if !session.isReadOnly {
                Button("Overwrite with my changes", role: .destructive) { Task { await session.save(force: true) } }
            }
            Button("Not now", role: .cancel) {}
        } message: { conflict in
            Text(message(for: conflict))
        }
        .alert("Your changes keep being overwritten", isPresented: $session.showOverwriteWarning) {
            Button("Save again") { Task { await session.saveAgainAfterOverwrite() } }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Another device or sync tool put back a version of the database without your latest changes, more than once. Your changes are kept on this iPhone, but SaveKey stopped saving them automatically. If you sync with “rclone copy”, use “rclone bisync” so changes go both ways.")
        }
        .alert("Couldn’t merge the copy", isPresented: Binding(get: { session.mergeError != nil },
                                                             set: { if !$0 { session.mergeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.mergeError ?? "")
        }
        .alert("Couldn’t follow the folder", isPresented: Binding(get: { folderError != nil },
                                                                set: { if !$0 { folderError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
    }

    /// Opens the folder picker once the alert has gone away.
    private func chooseFolderAfterAlert() {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            choosingFolder = true
        }
    }

    private func message(for conflict: FileConflict) -> String {
        switch conflict {
        case .differentKey:
            return session.isReadOnly
                ? String(localized: "The file was saved elsewhere with a different password or key file. Lock the database and unlock it with the new one to see the latest version.")
                : String(localized: "The file was saved elsewhere with a different password or key file. Lock the database and unlock it with the new one, or overwrite the file with this version.")
        case .unreadable(let detail):
            return String(localized: "The file was changed by another app or device, but SaveKey couldn’t read the new version: \(detail)")
        }
    }

    /// Follows the database by name in the chosen folder, then saves or checks for changes there.
    private func follow(in folder: URL) {
        let fileName = session.file.fileName
        let candidate = ScopedFile(url: folder.appendingPathComponent(fileName, isDirectory: false), scope: folder)
        Task {
            guard await Task.detached(operation: { FileAccess.exists(candidate) }).value else {
                folderError = BookmarkError.notInFolder(file: fileName, folder: folder.lastPathComponent).localizedDescription
                return
            }
            do {
                try library.follow(session.reference, inFolder: folder, fileName: fileName)
                await session.useFolder(folder)
            } catch {
                folderError = error.localizedDescription
            }
        }
    }
}

enum PendingDeletion {
    case entry(KPEntry)
    case group(KPGroup)
}

enum MoveItem: Identifiable {
    case entry(KPEntry)
    case group(KPGroup)
    var id: UUID {
        switch self {
        case .entry(let e): return e.uuid
        case .group(let g): return g.uuid
        }
    }
}

struct GroupView: View {
    let group: KPGroup
    var isRoot = false
    /// Shows the folder picker when the file was replaced and its folder is needed (root only).
    var onChooseFolder: (() -> Void)? = nil

    @EnvironmentObject private var session: DatabaseSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appState: AppState

    @State private var searchText = ""
    @State private var showNewEntry = false
    @State private var showNewCard = false
    @State private var showNewNote = false
    @State private var showNewGroup = false
    @State private var editingGroup: KPGroup?
    @State private var moving: MoveItem?
    @State private var pendingDeletion: PendingDeletion?
    @State private var confirmEmptyBin = false
    @State private var showDatabaseSettings = false
    @State private var showGenerator = false
    @State private var showAppSettings = false

    private var db: Database { session.database }
    private var isRecycleBin: Bool { db.recycleBin === group }
    /// Cards are created here when inside the Banking folder, otherwise in the Banking folder.
    private var isBankingFolder: Bool { CardFolder.contains(group, in: db) }
    /// The Notes folder holds secure notes: no credentials or one-time passwords.
    private var isNotesFolder: Bool { NotesFolder.contains(group, in: db) }
    private var canEdit: Bool { !session.isReadOnly }

    private var visibleGroups: [KPGroup] {
        group.groups
            .filter { settings.showRecycleBin || $0 !== db.recycleBin }
            .sorted { a, b in
                if a === db.recycleBin { return false }
                if b === db.recycleBin { return true }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    private var isEmptyGroup: Bool { group.entries.isEmpty && visibleGroups.isEmpty }

    /// Shown over the list when the group has no entries or subgroups.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isRecycleBin ? "trash" : (isNotesFolder ? "note.text" : "tray"))
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(isRecycleBin ? "The Recycle Bin is empty" : (isNotesFolder ? "No notes yet" : "This group is empty"))
                .foregroundStyle(.secondary)
            if canEdit && !isRecycleBin {
                HStack(spacing: 12) {
                    if isNotesFolder {
                        Button {
                            showNewNote = true
                        } label: {
                            Label("Add note", systemImage: "note.text")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        if isBankingFolder {
                            Button {
                                showNewCard = true
                            } label: {
                                Label("Add card", systemImage: "creditcard")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Add entry") { showNewEntry = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(24)
    }

    var body: some View {
        List {
            Group {
                if searchText.isEmpty {
                    groupContents
                } else {
                    searchResults
                }
            }
            .themedRows()
        }
        .themedBackground()
        .overlay {
            if searchText.isEmpty && isEmptyGroup { emptyState }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isRoot ? session.displayName : group.name)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: isRoot ? .always : .automatic),
                    prompt: "Search all entries")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showNewCard) {
            CardEditView(mode: .create(isBankingFolder ? group : nil))
                .environmentObject(session)
        }
        .sheet(isPresented: $showNewEntry) {
            EntryEditView(mode: .create(group))
                .environmentObject(session)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showNewNote) {
            EntryEditView(mode: .createNote(isNotesFolder ? group : nil))
                .environmentObject(session)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showNewGroup) {
            GroupEditView(mode: .create(group))
                .environmentObject(session)
        }
        .sheet(item: $editingGroup) { g in
            GroupEditView(mode: .edit(g))
                .environmentObject(session)
        }
        .sheet(item: $moving) { item in
            MoveView(item: item)
                .environmentObject(session)
        }
        .sheet(isPresented: $showDatabaseSettings) {
            DatabaseSettingsView()
                .environmentObject(session)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showGenerator) {
            PasswordGeneratorView()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showAppSettings) {
            AppSettingsView()
                .environmentObject(settings)
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { pendingDeletion != nil },
                                                                set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { item in
            Button(deletesPermanently(item) ? "Delete permanently" : "Move to Recycle Bin", role: .destructive) {
                perform(item)
            }
        } message: { item in
            if deletesPermanently(item) { Text("This cannot be undone.") }
        }
        .confirmationDialog("Empty the Recycle Bin?", isPresented: $confirmEmptyBin, titleVisibility: .visible) {
            Button("Empty Recycle Bin", role: .destructive) {
                db.emptyRecycleBin()
                session.commit()
            }
        } message: {
            Text("All entries and groups in the Recycle Bin will be permanently deleted.")
        }
    }

    // MARK: Sections

    @ViewBuilder private var groupContents: some View {
        if isRoot && session.isReadOnly {
            Section {
                Label("Opened read-only. Changes cannot be saved.", systemImage: "lock.doc")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if isRoot {
            syncBanners
        }
        let groups = visibleGroups
        if !groups.isEmpty {
            Section("Groups") {
                ForEach(groups) { child in
                    NavigationLink {
                        GroupView(group: child)
                    } label: {
                        GroupRow(group: child, customIcon: session.customIcon(child.customIconUUID))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canEdit {
                            Button(role: .destructive) { pendingDeletion = .group(child) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editingGroup = child } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        if canEdit {
                            Button { editingGroup = child } label: { Label("Edit group", systemImage: "pencil") }
                            Button { moving = .group(child) } label: { Label("Move…", systemImage: "folder") }
                            Button(role: .destructive) { pendingDeletion = .group(child) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        let entries = settings.entrySort.sorted(group.entries)
        Section {
            ForEach(entries) { entry in
                entryLink(entry, showPath: false)
            }
        } header: {
            if !entries.isEmpty { Text("Entries") }
        }
    }

    /// Notices about the file: replaced by a sync tool, or conflict copies to merge.
    @ViewBuilder private var syncBanners: some View {
        if session.needsFolder, let onChooseFolder {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The file was replaced by a new copy", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Text("A sync tool replaced the database file, so SaveKey no longer sees its changes. Choose the folder that contains it, and SaveKey will follow the file by its name.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    onChooseFolder()
                } label: {
                    Label("Choose folder…", systemImage: "folder")
                }
            }
        }
        ForEach(session.conflictCopies) { copy in
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Conflict copy found", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                    Text(copy.displayName)
                        .font(.footnote.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Group {
                        if case .iCloudVersion = copy.kind {
                            Text("iCloud kept this version because two devices saved the database at the same time. Merge it to keep the changes from both.")
                        } else {
                            Text("A sync tool kept this copy because the database changed on two devices at the same time. Merge it to keep the changes from both; the copy then moves to Recently Deleted.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if session.mergingCopyID == copy.id {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Merging…").foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await session.mergeConflictCopy(copy) }
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(session.mergingCopyID != nil)
                    Button {
                        session.ignoreConflictCopy(copy)
                    } label: {
                        Label("Ignore for now", systemImage: "eye.slash")
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = settings.entrySort.sorted(db.search(searchText))
        if results.isEmpty {
            Text("No matching entries")
                .foregroundStyle(.secondary)
        } else {
            Section(results.count == 1 ? String(localized: "1 result") : String(localized: "\(results.count) results")) {
                ForEach(results) { entry in
                    entryLink(entry, showPath: true)
                }
            }
        }
    }

    private func entryLink(_ entry: KPEntry, showPath: Bool) -> some View {
        let isNote = PaymentCard.from(entry: entry) == nil && NotesFolder.contains(entry, in: db)
        return NavigationLink {
            EntryDetailView(entry: entry)
        } label: {
            EntryRow(entry: entry, customIcon: session.customIcon(entry.customIconUUID), showPath: showPath, isNote: isNote)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !entry.password.isEmpty {
                Button { ToastCenter.shared.copied(entry.password, label: String(localized: "Password")) } label: {
                    Label("Password", systemImage: "key.fill")
                }
                .tint(.blue)
            }
            if !entry.userName.isEmpty {
                Button { ToastCenter.shared.copied(entry.userName, label: String(localized: "Username"), sensitive: false) } label: {
                    Label("Username", systemImage: "person.fill")
                }
                .tint(.gray)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canEdit {
                Button(role: .destructive) { pendingDeletion = .entry(entry) } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { moving = .entry(entry) } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            if isNote && !entry.notes.isEmpty {
                Button { ToastCenter.shared.copied(entry.notes, label: String(localized: "Note")) } label: {
                    Label("Copy note", systemImage: "doc.on.doc")
                }
            }
            if !entry.userName.isEmpty {
                Button { ToastCenter.shared.copied(entry.userName, label: String(localized: "Username"), sensitive: false) } label: {
                    Label("Copy username", systemImage: "person")
                }
            }
            if !entry.password.isEmpty {
                Button { ToastCenter.shared.copied(entry.password, label: String(localized: "Password")) } label: {
                    Label("Copy password", systemImage: "key")
                }
            }
            if let otp = OTPConfig.from(entry: entry), otp.isTimeBased {
                Button { ToastCenter.shared.copied(otp.code(), label: String(localized: "One-time code")) } label: {
                    Label("Copy one-time code", systemImage: "clock")
                }
            }
            if canEdit {
                Divider()
                Button { moving = .entry(entry) } label: { Label("Move…", systemImage: "folder") }
                Button(role: .destructive) { pendingDeletion = .entry(entry) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    appState.lock()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if session.isSaving {
                ProgressView()
            }
            if canEdit && !isRecycleBin {
                Menu {
                    if isNotesFolder {
                        Button { showNewNote = true } label: { Label("New note", systemImage: "note.text") }
                    } else if isBankingFolder {
                        Button { showNewCard = true } label: { Label("New card", systemImage: "creditcard") }
                        Button { showNewEntry = true } label: { Label("New entry", systemImage: "key.fill") }
                        Button { showNewNote = true } label: { Label("New note (in Notes)", systemImage: "note.text") }
                    } else {
                        Button { showNewEntry = true } label: { Label("New entry", systemImage: "key.fill") }
                        Button { showNewCard = true } label: { Label("New card (in Banking)", systemImage: "creditcard") }
                        Button { showNewNote = true } label: { Label("New note (in Notes)", systemImage: "note.text") }
                    }
                    Button { showNewGroup = true } label: { Label("New group", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
            Menu {
                Picker("Sort entries by", selection: $settings.entrySort) {
                    ForEach(EntrySort.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                if isRecycleBin && canEdit {
                    Button(role: .destructive) { confirmEmptyBin = true } label: {
                        Label("Empty Recycle Bin", systemImage: "trash.slash")
                    }
                }
                if !isRoot && !isRecycleBin && canEdit {
                    Button { editingGroup = group } label: { Label("Edit group", systemImage: "pencil") }
                }
                Button { showGenerator = true } label: { Label("Password generator", systemImage: "dice") }
                Button { showDatabaseSettings = true } label: { Label("Database settings", systemImage: "cylinder.split.1x2") }
                Button { showAppSettings = true } label: { Label("App settings", systemImage: "gearshape") }
                Divider()
                Button { appState.lock() } label: { Label("Lock database", systemImage: "lock") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: Deletion

    private var deletionTitle: String {
        switch pendingDeletion {
        case .entry(let e)?: return String(localized: "Delete “\(e.title)”?")
        case .group(let g)?: return String(localized: "Delete group “\(g.name)”?")
        case nil: return ""
        }
    }

    private func deletesPermanently(_ item: PendingDeletion) -> Bool {
        guard db.meta.recycleBinEnabled else { return true }
        switch item {
        case .entry(let e): return db.isInRecycleBin(e)
        case .group(let g): return db.isInRecycleBin(g)
        }
    }

    private func perform(_ item: PendingDeletion) {
        switch item {
        case .entry(let e): db.delete(e)
        case .group(let g): db.delete(g)
        }
        session.commit()
    }
}

struct GroupRow: View {
    let group: KPGroup
    var customIcon: CustomIcon?

    var body: some View {
        HStack(spacing: 12) {
            KeePassIconView(iconID: group.iconID, customIcon: customIcon, size: 34, isGroup: true)
            Text(group.name.isEmpty ? String(localized: "(unnamed)") : group.name)
                .lineLimit(1)
            Spacer()
            Text("\(group.allEntries.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Picks a destination group for moving an entry or group.
struct MoveView: View {
    let item: MoveItem
    @EnvironmentObject private var session: DatabaseSession
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let group: KPGroup
        let depth: Int
        var id: UUID { group.uuid }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func walk(_ g: KPGroup, _ depth: Int) {
            result.append(Row(group: g, depth: depth))
            for c in g.groups.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                walk(c, depth + 1)
            }
        }
        walk(session.database.root, 0)
        return result
    }

    private func isValid(_ target: KPGroup) -> Bool {
        switch item {
        case .entry(let e): return e.parent !== target
        case .group(let g): return g !== target && !target.isDescendant(of: g) && g.parent !== target
        }
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button {
                    switch item {
                    case .entry(let e): session.database.move(e, to: row.group)
                    case .group(let g): session.database.move(g, to: row.group)
                    }
                    session.commit()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        KeePassIconView(iconID: row.group.iconID, customIcon: session.customIcon(row.group.customIconUUID),
                                        size: 28, isGroup: true)
                        Text(row.depth == 0 ? session.displayName : row.group.name)
                            .foregroundStyle(isValid(row.group) ? .primary : .secondary)
                    }
                    .padding(.leading, CGFloat(row.depth) * 18)
                }
                .disabled(!isValid(row.group))
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
