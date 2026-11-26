// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

/// Editable copy of an entry. Changes are applied only when the user taps Save.
struct EntryDraft: Equatable {
    struct CustomField: Equatable, Identifiable {
        var id = UUID()
        var key: String
        var value: String
        var isProtected: Bool
    }

    var title = ""
    var userName = ""
    var password = ""
    var url = ""
    var notes = ""
    var tags = ""
    var iconID = 0
    var customIconUUID: UUID?
    var expires = false
    var expiry = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    var customFields: [CustomField] = []
    var attachments: [Attachment] = []
    var otp: OTPConfig?
    var otpChanged = false

    init(defaultUserName: String) {
        userName = defaultUserName
    }

    init(entry: KPEntry) {
        title = entry.title
        userName = entry.userName
        password = entry.password
        url = entry.url
        notes = entry.notes
        tags = entry.tags.joined(separator: ", ")
        iconID = entry.iconID
        customIconUUID = entry.customIconUUID
        expires = entry.times.expires
        if entry.times.expires { expiry = entry.times.expiry }
        customFields = entry.customFields
            .filter { !OTPConfig.isOTPField($0.key) }
            .map { CustomField(key: $0.key, value: $0.value, isProtected: $0.isProtected) }
        attachments = entry.attachments
        otp = OTPConfig.from(entry: entry)
    }

    static func == (a: EntryDraft, b: EntryDraft) -> Bool {
        a.title == b.title && a.userName == b.userName && a.password == b.password && a.url == b.url &&
            a.notes == b.notes && a.tags == b.tags && a.iconID == b.iconID && a.customIconUUID == b.customIconUUID &&
            a.expires == b.expires && (!a.expires || a.expiry == b.expiry) && a.attachments == b.attachments &&
            a.otp == b.otp && a.otpChanged == b.otpChanged &&
            a.customFields.map { [$0.key, $0.value, String($0.isProtected)] } ==
            b.customFields.map { [$0.key, $0.value, String($0.isProtected)] }
    }

    var parsedTags: [String] {
        tags.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns an error message if the draft cannot be saved.
    func validate() -> String? {
        var seen = Set<String>()
        for f in customFields {
            let key = f.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty { return String(localized: "Custom fields need a name.") }
            if KPEntry.standardKeys.contains(key) || OTPConfig.isOTPField(key) { return String(localized: "“\(key)” is a reserved field name.") }
            if !seen.insert(key).inserted { return String(localized: "There are two fields named “\(key)”.") }
        }
        var names = Set<String>()
        for a in attachments where !names.insert(a.name).inserted {
            return String(localized: "There are two attachments named “\(a.name)”.")
        }
        return nil
    }

    func apply(to entry: KPEntry, protection: MemoryProtection) {
        func set(_ key: String, _ value: String) {
            let wasProtected = entry.field(key)?.isProtected
            entry.setValue(value, for: key, protected: wasProtected ?? protection.shouldProtect(key))
        }
        set(KPEntry.titleKey, title)
        set(KPEntry.userNameKey, userName)
        set(KPEntry.passwordKey, password)
        set(KPEntry.urlKey, url)
        set(KPEntry.notesKey, notes)
        entry.tags = parsedTags
        entry.iconID = iconID
        entry.customIconUUID = customIconUUID
        entry.times.expires = expires
        if expires { entry.times.expiry = expiry }

        // Replace custom fields, keeping OTP fields unless the OTP was edited.
        let keptOTPFields = otpChanged ? [] : entry.fields.filter { OTPConfig.isOTPField($0.key) }
        entry.fields.removeAll { !KPEntry.standardKeys.contains($0.key) }
        entry.fields += customFields.map {
            EntryField(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value, isProtected: $0.isProtected)
        }
        entry.fields += keptOTPFields
        if otpChanged {
            OTPConfig.remove(from: entry)
            otp?.apply(to: entry)
        }
        entry.attachments = attachments
    }
}

struct EntryEditView: View {
    enum Mode {
        case create(KPGroup)
        /// A new secure note; `nil` stores it in the Notes folder (created if needed).
        case createNote(KPGroup?)
        case edit(KPEntry)
    }

    let mode: Mode
    /// Secure-note layout: the note comes first and the credentials and one-time password sections are
    /// left out. They still appear if the entry already has them, so nothing is hidden.
    let isNote: Bool
    @EnvironmentObject private var session: DatabaseSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var draft: EntryDraft
    @State private var original: EntryDraft
    @State private var showPassword = false
    @State private var showGenerator = false
    @State private var showIconPicker = false
    @State private var showOTPSetup = false
    @State private var showAttachmentPicker = false
    @State private var revealedFields: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    init(mode: Mode, isNote: Bool = false) {
        self.mode = mode
        var d: EntryDraft
        switch mode {
        case .create:
            d = EntryDraft(defaultUserName: "")
            self.isNote = isNote
        case .createNote:
            d = EntryDraft(defaultUserName: "")
            d.iconID = NotesFolder.iconID
            self.isNote = true
        case .edit(let e):
            d = EntryDraft(entry: e)
            self.isNote = isNote
        }
        _draft = State(initialValue: d)
        _original = State(initialValue: d)
    }

    private var isNew: Bool {
        if case .edit = mode { return false }
        return true
    }

    private var isNewNote: Bool {
        if case .createNote = mode { return true }
        return false
    }

    /// Notes show these sections only when the entry already had something in them.
    private var showsCredentials: Bool {
        !isNote || !original.userName.isEmpty || !original.password.isEmpty || !original.url.isEmpty
    }

    private var showsOTP: Bool { !isNote || original.otp != nil }

    private var screenTitle: String {
        if isNote { return isNew ? String(localized: "New note") : String(localized: "Edit note") }
        return isNew ? String(localized: "New entry") : String(localized: "Edit entry")
    }

    /// A new note needs a title, some text or an attachment.
    private var canSave: Bool {
        guard isNewNote else { return true }
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !draft.attachments.isEmpty
    }

    private var noteFolderName: String {
        if case .createNote(let group?) = mode { return group.name }
        return NotesFolder.find(in: session.database)?.name ?? NotesFolder.defaultName
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    titleSection
                    if isNote { notesSection }
                    if showsCredentials { credentialsSection }
                    if showsOTP { otpSection }
                    customFieldsSection
                    if !isNote { notesSection }
                    tagsSection
                    expirationSection
                    attachmentsSection
                    if isNewNote {
                        Section {
                            Label("Saved in “\(noteFolderName)”", systemImage: "folder")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft != original { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .bold()
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(draft != original)
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .alert("Cannot save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showGenerator) {
                PasswordGeneratorView { generated in
                    draft.password = generated
                    showPassword = true
                }
                .environmentObject(settings)
            }
            .sheet(isPresented: $showIconPicker) {
                IconPickerView(iconID: $draft.iconID, customIconUUID: $draft.customIconUUID)
                    .environmentObject(session)
            }
            .sheet(isPresented: $showOTPSetup) {
                OTPSetupView(initial: draft.otp, defaultIssuer: draft.title, defaultAccount: draft.userName) { config in
                    draft.otp = config
                    draft.otpChanged = true
                }
            }
            .fileImporter(isPresented: $showAttachmentPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                addAttachments(urls)
            }
            .pausesFileSync(session)
            .onAppear {
                if case .create = mode, draft == original, draft.userName.isEmpty {
                    draft.userName = session.database.meta.defaultUserName
                    original = draft
                }
            }
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    showIconPicker = true
                } label: {
                    KeePassIconView(iconID: draft.iconID, customIcon: session.customIcon(draft.customIconUUID), size: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose icon")
                TextField("Title", text: $draft.title)
                    .font(.headline)
            }
        }
    }

    private var credentialsSection: some View {
        Section("Credentials") {
            TextField("Username", text: $draft.userName)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Group {
                        if showPassword {
                            TextField("Password", text: $draft.password)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("Password", text: $draft.password)
                        }
                    }
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        showGenerator = true
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Generate password")
                }
                if !draft.password.isEmpty {
                    StrengthBar(bits: PasswordStrength.estimateBits(draft.password))
                }
            }
            TextField("URL", text: $draft.url)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var otpSection: some View {
        Section("One-time password") {
            if let otp = draft.otp {
                HStack {
                    VStack(alignment: .leading) {
                        Text(otpSummary(otp))
                        if !otp.issuer.isEmpty || !otp.account.isEmpty {
                            Text([otp.issuer, otp.account].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { showOTPSetup = true }
                        .buttonStyle(.borderless)
                }
                Button("Remove one-time password", role: .destructive) {
                    draft.otp = nil
                    draft.otpChanged = true
                }
            } else {
                Button {
                    showOTPSetup = true
                } label: {
                    Label("Set up one-time password", systemImage: "qrcode.viewfinder")
                }
            }
        }
    }

    private var customFieldsSection: some View {
        Section {
            ForEach($draft.customFields) { $field in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Field name", text: $field.key)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                    HStack {
                        if field.isProtected && !revealedFields.contains(field.id) {
                            SecureField("Value", text: $field.value)
                        } else {
                            TextField("Value", text: $field.value)
                        }
                        Button {
                            field.isProtected.toggle()
                        } label: {
                            Image(systemName: field.isProtected ? "lock.fill" : "lock.open")
                                .foregroundStyle(field.isProtected ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(field.isProtected ? "Protected" : "Not protected")
                        if field.isProtected {
                            Button {
                                if revealedFields.contains(field.id) {
                                    revealedFields.remove(field.id)
                                } else {
                                    revealedFields.insert(field.id)
                                }
                            } label: {
                                Image(systemName: revealedFields.contains(field.id) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .onDelete { draft.customFields.remove(atOffsets: $0) }
            Button {
                draft.customFields.append(.init(key: "", value: "", isProtected: false))
            } label: {
                Label("Add field", systemImage: "plus.circle")
            }
        } header: {
            Text("Custom fields")
        } footer: {
            Text("Tap the lock to mark a field as protected (hidden and encrypted in memory).")
        }
    }

    private var notesSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.notes)
                    .frame(minHeight: isNote ? 220 : 100)
                if isNote && draft.notes.isEmpty {
                    Text("Write your note")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        } header: {
            Text(isNote ? "Note" : "Notes")
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            TextField("e.g. work, finance", text: $draft.tags)
                .textInputAutocapitalization(.never)
        }
    }

    private var expirationSection: some View {
        Section("Expiration") {
            Toggle("Expires", isOn: $draft.expires.animation())
            if draft.expires {
                DatePicker("Expiry date", selection: $draft.expiry)
            }
        }
    }

    private var attachmentsSection: some View {
        Section("Attachments") {
            ForEach(draft.attachments) { a in
                HStack {
                    Image(systemName: "doc")
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { draft.attachments.remove(atOffsets: $0) }
            Button {
                showAttachmentPicker = true
            } label: {
                Label("Add attachment", systemImage: "paperclip")
            }
        }
    }

    // MARK: Actions

    private func otpSummary(_ otp: OTPConfig) -> String {
        switch otp.kind {
        case .totp: return String(localized: "TOTP · \(otp.digits) digits · \(otp.period) s · \(otp.algorithm.rawValue)")
        case .hotp(let c): return String(localized: "HOTP · \(otp.digits) digits · counter \(String(c))")
        case .steam: return "Steam Guard"
        }
    }

    private func addAttachments(_ urls: [URL]) {
        for url in urls {
            do {
                let data = try FileAccess.readPicked(url)
                var name = url.lastPathComponent
                var n = 2
                while draft.attachments.contains(where: { $0.name == name }) {
                    let base = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    n += 1
                }
                draft.attachments.append(Attachment(name: name, data: data))
            } catch {
                errorMessage = String(localized: "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        if let problem = draft.validate() {
            errorMessage = problem
            return
        }
        let db = session.database
        let protection = db.meta.memoryProtection
        switch mode {
        case .create(let group):
            let entry = db.createEntry(in: group)
            draft.apply(to: entry, protection: protection)
            entry.times.touch(modified: true)
        case .createNote(let group):
            var note = draft
            if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note.title = String(localized: "Note") }
            // The draft has no username, which also clears the database's default username.
            let entry = db.createEntry(in: group ?? NotesFolder.findOrCreate(in: db))
            note.apply(to: entry, protection: protection)
            entry.times.touch(modified: true)
        case .edit(let entry):
            guard draft != original else {
                dismiss()
                return
            }
            let (maxItems, maxSize) = session.historyLimits()
            entry.backupToHistory(maxItems: maxItems, maxSize: maxSize)
            draft.apply(to: entry, protection: protection)
            entry.times.touch(modified: true)
        }
        session.commit()
        dismiss()
    }
}

struct GroupEditView: View {
    enum Mode {
        case create(KPGroup)
        case edit(KPGroup)
    }

    let mode: Mode
    @EnvironmentObject private var session: DatabaseSession
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var notes = ""
    @State private var iconID = 48
    @State private var customIconUUID: UUID?
    @State private var searchSetting = 0 // 0 inherit, 1 yes, 2 no
    @State private var showIconPicker = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                showIconPicker = true
                            } label: {
                                KeePassIconView(iconID: iconID, customIcon: session.customIcon(customIconUUID), size: 44, isGroup: true)
                            }
                            .buttonStyle(.plain)
                            TextField("Group name", text: $name)
                                .font(.headline)
                        }
                    }
                    Section("Notes") {
                        TextEditor(text: $notes).frame(minHeight: 80)
                    }
                    Section {
                        Picker("Include in search", selection: $searchSetting) {
                            Text("Inherit").tag(0)
                            Text("Yes").tag(1)
                            Text("No").tag(2)
                        }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle(isNew ? "New group" : "Edit group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showIconPicker) {
                IconPickerView(iconID: $iconID, customIconUUID: $customIconUUID, isGroup: true)
                    .environmentObject(session)
            }
            .onAppear(perform: load)
            .pausesFileSync(session)
        }
    }

    private var isNew: Bool {
        if case .create = mode { return true }
        return false
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .edit(let g) = mode {
            name = g.name
            notes = g.notes
            iconID = g.iconID
            customIconUUID = g.customIconUUID
            switch g.enableSearching {
            case nil: searchSetting = 0
            case true?: searchSetting = 1
            case false?: searchSetting = 2
            }
        }
    }

    private func save() {
        let target: KPGroup
        switch mode {
        case .create(let parent):
            target = session.database.createGroup(named: name, in: parent)
        case .edit(let g):
            target = g
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.notes = notes
        target.iconID = iconID
        target.customIconUUID = customIconUUID
        target.enableSearching = searchSetting == 0 ? nil : searchSetting == 1
        target.times.touch(modified: true)
        session.commit()
        dismiss()
    }
}
