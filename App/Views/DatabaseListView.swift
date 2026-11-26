// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

struct DatabaseListView: View {
    @EnvironmentObject private var library: DatabaseLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appState: AppState

    @State private var showImporter = false
    @State private var importTarget = ImportTarget.database
    @State private var folderChoice: FolderChoice?
    @State private var showCreate = false
    @State private var showSettings = false
    @State private var showGenerator = false
    @State private var unlocking: DatabaseReference?
    @State private var removing: DatabaseReference?
    @State private var importError: String?

    /// What the (single) file importer is choosing.
    private enum ImportTarget {
        /// A database file.
        case database
        /// A folder, to open a database in it by name.
        case folder
        /// The folder of an existing database, to follow it there by name.
        case follow(DatabaseReference)
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.references.isEmpty {
                    emptyState
                } else {
                    databaseList
                }
            }
            .navigationTitle("Databases")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showGenerator = true
                    } label: {
                        Image(systemName: "dice")
                    }
                    .accessibilityLabel("Password generator")
                    Menu {
                        Button {
                            choose(.database)
                        } label: {
                            Label("Open existing database", systemImage: "doc")
                        }
                        Button {
                            choose(.folder)
                        } label: {
                            Label("Open from a synced folder", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            showCreate = true
                        } label: {
                            Label("Create new database", systemImage: "plus.square.on.square")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add database")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url):
                switch importTarget {
                case .database: importDatabase(url)
                case .folder: openFolder(url, following: nil)
                case .follow(let ref): openFolder(url, following: ref)
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(item: $folderChoice) { choice in
            FolderDatabasePicker(choice: choice) { name in
                folderChoice = nil
                pick(name, in: choice)
            }
        }
        .sheet(item: $unlocking) { ref in
            NavigationStack {
                UnlockView(reference: ref) { session in
                    unlocking = nil
                    appState.session = session
                    CredentialIdentities.update(for: session.database, reference: ref)
                }
                .navigationTitle("Unlock")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { unlocking = nil }
                    }
                }
            }
            .environmentObject(library)
            .environmentObject(settings)
        }
        .sheet(isPresented: $showCreate) {
            NewDatabaseView { session in
                showCreate = false
                appState.session = session
            }
            .environmentObject(library)
            .environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showGenerator) {
            PasswordGeneratorView()
                .environmentObject(settings)
        }
        .alert("Remove from list?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { ref in
            Button("Remove", role: .destructive) { library.remove(ref) }
            Button("Cancel", role: .cancel) {}
        } message: { ref in
            Text("“\(ref.fileName)” will be removed from SaveKey. The file itself is not deleted.")
        }
        .alert("Could not open database", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onReceive(appState.$pendingUnlock) { ref in
            guard let ref else { return }
            appState.pendingUnlock = nil
            unlocking = ref
        }
        .onAppear {
            library.reload()
            guard appState.shouldAutoOpenLastDatabase, appState.pendingUnlock == nil else { return }
            appState.shouldAutoOpenLastDatabase = false
            if let last = library.lastUsedID, let ref = library.reference(id: last) {
                unlocking = ref
            }
        }
    }

    private var databaseList: some View {
        List {
            Group {
                Section {
                    ForEach(library.references) { ref in
                        Button {
                            unlocking = ref
                        } label: {
                            DatabaseRow(reference: ref)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                removing = ref
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            Button {
                                choose(.follow(ref))
                            } label: {
                                Label("Follow in folder…", systemImage: "folder.badge.gearshape")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                choose(.follow(ref))
                            } label: {
                                Label("Follow in folder…", systemImage: "folder.badge.gearshape")
                            }
                            Button(role: .destructive) {
                                removing = ref
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    .onMove { library.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Databases stay where they are (On My iPhone, iCloud Drive, Dropbox…). SaveKey opens and saves them in place.")
                        Text("If a sync tool such as rclone or Syncthing keeps replacing the file, use “Follow in folder…” so SaveKey finds it by its name.")
                    }
                }
            }
            .themedRows()
        }
        .themedBackground()
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 130, height: 130)
                .accessibilityHidden(true)
            Text("No databases yet").font(.title2.bold())
            Text("Open an existing KeePass database (.kdbx) or create a new one.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            VStack(spacing: 12) {
                Button {
                    choose(.database)
                } label: {
                    Label("Open existing database", systemImage: "doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    choose(.folder)
                } label: {
                    Label("Open from a synced folder", systemImage: "folder.badge.gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    showCreate = true
                } label: {
                    Label("Create new database", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }

    private var importTypes: [UTType] {
        if case .database = importTarget { return [.kdbx, .data, .item] }
        return [.folder]
    }

    private func choose(_ target: ImportTarget) {
        importTarget = target
        showImporter = true
    }

    /// Lists the databases in a chosen folder. When following an existing database whose file is
    /// there, follows it right away.
    private func openFolder(_ folder: URL, following ref: DatabaseReference?) {
        Task {
            do {
                let items = try await Task.detached { try FileAccess.listFolder(folder) }.value
                if let ref, items.contains(where: { $0.name == ref.fileName }) {
                    try library.follow(ref, inFolder: folder, fileName: ref.fileName)
                    ToastCenter.shared.show(String(localized: "SaveKey now follows “\(ref.fileName)” in “\(folder.lastPathComponent)”"))
                    return
                }
                folderChoice = FolderChoice(folder: folder, items: items, following: ref)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func pick(_ name: String, in choice: FolderChoice) {
        do {
            if let ref = choice.following {
                try library.follow(ref, inFolder: choice.folder, fileName: name)
                ToastCenter.shared.show(String(localized: "SaveKey now follows “\(name)” in “\(choice.folder.lastPathComponent)”"))
            } else {
                let ref = try library.add(folder: choice.folder, fileName: name)
                // Let the folder sheet close before the unlock sheet opens.
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    unlocking = ref
                }
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importDatabase(_ url: URL) {
        Task {
            do {
                let head = try await Task.detached { try FileAccess.read(url).data.prefix(12) }.value
                guard KDBX.isKeePassFile(Data(head)) else {
                    importError = String(localized: "“\(url.lastPathComponent)” is not a KeePass database.")
                    return
                }
                let ref = try library.add(url: url)
                unlocking = ref
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

struct DatabaseRow: View {
    let reference: DatabaseReference

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.title3)
                .foregroundStyle(Theme.iconSymbol)
                .frame(width: 40, height: 40)
                .background(Theme.iconTile, in: RoundedRectangle(cornerRadius: 10.4, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(reference.name).font(.headline)
                HStack(spacing: 4) {
                    Text(reference.fileName)
                    if let opened = reference.lastOpened {
                        Text("·")
                        // "2 hours ago", worded by iOS in the app's language.
                        Text(opened.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if reference.followsFolder {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Follows the file in its folder")
            }
            if reference.opensReadOnly == true {
                Image(systemName: "lock.doc")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Opens read-only")
            }
            if BiometricKeyStore.hasKey(for: reference.id) {
                Image(systemName: BiometricKeyStore.biometrySymbol)
                    .foregroundStyle(.secondary)
            }
            if reference.keyFileName != nil {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

/// A folder chosen for opening a database by name.
struct FolderChoice: Identifiable {
    let folder: URL
    let items: [FolderItem]
    /// The database that will follow the chosen file, or nil to add a new one.
    let following: DatabaseReference?
    var id: URL { folder }
}

/// Lists the KeePass databases in a folder so one can be opened, or followed, by its name.
struct FolderDatabasePicker: View {
    let choice: FolderChoice
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showAllFiles = false

    private var databases: [FolderItem] {
        choice.items.filter { ($0.name as NSString).pathExtension.lowercased() == "kdbx" }
    }

    private var listed: [FolderItem] { showAllFiles ? choice.items : databases }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        if listed.isEmpty {
                            Text("No KeePass databases (.kdbx) in this folder.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(listed) { item in
                            Button {
                                onPick(item.name)
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label(choice.folder.lastPathComponent, systemImage: "folder")
                    } footer: {
                        Text("SaveKey will open the database by its name in this folder, so it keeps working when a sync tool replaces the file with a new copy.")
                    }
                    if !showAllFiles && databases.count != choice.items.count {
                        Section {
                            Button("Show all files") { showAllFiles = true }
                        }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Choose database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: FolderItem) -> some View {
        let isCopy = choice.items.contains { SyncConflictCopies.isConflictCopy(item.name, of: $0.name) }
        return HStack(spacing: 12) {
            Image(systemName: isCopy ? "doc.on.doc" : "cylinder.split.1x2.fill")
                .font(.title3)
                .foregroundStyle(Theme.iconSymbol)
                .frame(width: 36, height: 36)
                .background(Theme.iconTile, in: RoundedRectangle(cornerRadius: 9.4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if isCopy {
                        Text("Conflict copy")
                    }
                    if let modified = item.modified {
                        if isCopy { Text("·") }
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !item.isDownloaded {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not downloaded")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
