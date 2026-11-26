// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import KeePassCore

struct AutoFillRootView: View {
    @ObservedObject var model: AutoFillModel
    @EnvironmentObject private var library: DatabaseLibrary
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .toolbar {
                    if !isConfiguration {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.cancel() }
                        }
                    }
                    if model.session == nil, library.references.count > 1, !isConfiguration {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                ForEach(library.references) { ref in
                                    Button {
                                        model.switchDatabase(ref)
                                    } label: {
                                        if ref.id == model.selectedReference?.id {
                                            Label(ref.name, systemImage: "checkmark")
                                        } else {
                                            Text(ref.name)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "cylinder.split.1x2")
                            }
                            .accessibilityLabel("Choose database")
                        }
                    }
                }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var isConfiguration: Bool {
        if case .configuration = model.mode { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        if isConfiguration {
            ConfigurationView { model.finishConfiguration() }
        } else if let session = model.session {
            AutoFillEntryList(session: session, model: model)
        } else if let ref = model.selectedReference {
            UnlockView(reference: ref, forceReadOnly: true) { session in
                model.unlocked(session)
            }
            .id(ref.id)
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
                Text("No databases").font(.title3.bold())
                Text("Open SaveKey and add a database first. It will then be available here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AutoFillEntryList: View {
    @ObservedObject var session: DatabaseSession
    @ObservedObject var model: AutoFillModel
    @State private var search = ""

    private var matches: [KPEntry] {
        URLMatcher.matchingEntries(in: session.database, identifiers: model.identifierStrings)
    }

    private var allEntries: [KPEntry] {
        session.database.searchableEntries.filter { canFill($0) }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Notes have nothing to fill in, so they are left out of the lists.
    private func canFill(_ entry: KPEntry) -> Bool {
        entry.hasCredentials || !NotesFolder.contains(entry, in: session.database)
    }

    var body: some View {
        List {
            Group {
                if search.isEmpty {
                    let suggested = matches
                    if !suggested.isEmpty {
                        Section("Suggested for \(model.domainLabel)") {
                            ForEach(suggested) { row($0) }
                        }
                    } else {
                        Section {
                            Text("No entries match \(model.domainLabel). Search or pick one below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("All entries") {
                        ForEach(allEntries) { row($0) }
                    }
                } else {
                    let results = session.database.search(search).filter { canFill($0) }
                    if results.isEmpty {
                        Text("No matching entries").foregroundStyle(.secondary)
                    } else {
                        Section {
                            ForEach(results) { row($0) }
                        }
                    }
                }
            }
            .themedRows()
        }
        .themedBackground()
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: KPEntry) -> some View {
        Button {
            model.select(entry)
        } label: {
            EntryRow(entry: entry, customIcon: session.customIcon(entry.customIconUUID), showPath: true)
        }
        .buttonStyle(.plain)
    }
}

struct ConfigurationView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("SaveKey AutoFill is on").font(.title2.bold())
            Text("When you sign in to a website or app, tap the key icon above the keyboard and choose SaveKey.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
