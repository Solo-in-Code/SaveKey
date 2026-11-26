// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

enum KDFChoice: String, CaseIterable, Identifiable {
    case argon2id = "Argon2id", argon2d = "Argon2d", aes = "AES-KDF"
    var id: String { rawValue }
}

/// Editable encryption settings, shared by "new database" and "database settings".
struct SecurityDraft: Equatable {
    var cipher: Cipher = .aes256
    var kdf: KDFChoice = .argon2id
    var iterations = 4
    var memoryMiB = 64
    var parallelism = 2
    var aesRounds = 2_000_000
    var compression = true

    init() {}

    init(settings: DatabaseSettings) {
        cipher = settings.cipher
        compression = settings.compression
        switch settings.kdf {
        case .aes(let rounds, _):
            kdf = .aes
            aesRounds = Int(clamping: rounds)
        case .argon2(let p):
            kdf = p.variant == .d ? .argon2d : .argon2id
            iterations = Int(clamping: p.iterations)
            memoryMiB = max(1, Int(clamping: p.memoryBytes / (1024 * 1024)))
            parallelism = Int(p.parallelism)
        }
    }

    /// Builds settings, keeping the existing salt when the KDF parameters did not change.
    func makeSettings(base: DatabaseSettings?) -> DatabaseSettings {
        let kdfParams: KDFParameters
        switch kdf {
        case .aes:
            kdfParams = .aes(rounds: UInt64(max(aesRounds, 1)), seed: SecureRandom.bytes(32))
        case .argon2d, .argon2id:
            kdfParams = .argon2(.init(variant: kdf == .argon2d ? .d : .id, salt: SecureRandom.bytes(32),
                                      iterations: UInt64(max(iterations, 1)),
                                      memoryBytes: UInt64(max(memoryMiB, 1)) * 1024 * 1024,
                                      parallelism: UInt32(max(parallelism, 1))))
        }
        var s = base ?? DatabaseSettings()
        s.cipher = cipher
        s.compression = compression
        if let base, SecurityDraft(settings: base).sameKDF(as: self) {
            s.kdf = base.kdf
        } else {
            s.kdf = kdfParams
        }
        return s
    }

    func sameKDF(as other: SecurityDraft) -> Bool {
        guard kdf == other.kdf else { return false }
        switch kdf {
        case .aes: return aesRounds == other.aesRounds
        default: return iterations == other.iterations && memoryMiB == other.memoryMiB && parallelism == other.parallelism
        }
    }
}

struct SecuritySettingsSection: View {
    @Binding var draft: SecurityDraft
    @State private var benchmarking = false

    var body: some View {
        Section {
            Picker("Encryption", selection: $draft.cipher) {
                ForEach(Cipher.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Key derivation", selection: $draft.kdf) {
                ForEach(KDFChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            if draft.kdf == .aes {
                Stepper("Rounds: \(draft.aesRounds.formatted())", value: $draft.aesRounds, in: 1_000...100_000_000, step: 500_000)
            } else {
                Stepper("Iterations: \(draft.iterations)", value: $draft.iterations, in: 1...100)
                Stepper("Memory: \(draft.memoryMiB) MiB", value: $draft.memoryMiB, in: 1...512, step: draft.memoryMiB < 16 ? 1 : 16)
                Stepper("Parallelism: \(draft.parallelism)", value: $draft.parallelism, in: 1...8)
            }
            Button {
                benchmark()
            } label: {
                HStack {
                    Text("Calibrate for 1 second")
                    if benchmarking { Spacer(); ProgressView() }
                }
            }
            .disabled(benchmarking)
            Toggle("Compression", isOn: $draft.compression)
        } header: {
            Text("Security")
        } footer: {
            Text("Higher key-derivation cost makes brute-force attacks slower but unlocking slower too. Keep Argon2 memory at 64 MiB or less so Password AutoFill (which has limited memory) can still unlock the database.")
        }
    }

    private func benchmark() {
        benchmarking = true
        let d = draft
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Int in
                let start = Date()
                switch d.kdf {
                case .aes:
                    let rounds: UInt64 = 200_000
                    _ = try? KDFParameters.aes(rounds: rounds, seed: SecureRandom.bytes(32)).transform(SecureRandom.bytes(32))
                    let t = max(Date().timeIntervalSince(start), 0.001)
                    return Int(Double(rounds) / t)
                case .argon2d, .argon2id:
                    let p = KDFParameters.argon2(.init(variant: d.kdf == .argon2d ? .d : .id, salt: SecureRandom.bytes(32),
                                                       iterations: 1, memoryBytes: UInt64(d.memoryMiB) * 1024 * 1024,
                                                       parallelism: UInt32(d.parallelism)))
                    _ = try? p.transform(SecureRandom.bytes(32))
                    let t = max(Date().timeIntervalSince(start), 0.001)
                    return max(1, Int(1.0 / t))
                }
            }.value
            if d.kdf == .aes {
                draft.aesRounds = max(1_000, (result / 1_000) * 1_000)
            } else {
                draft.iterations = min(max(result, 1), 100)
            }
            benchmarking = false
        }
    }
}

struct DatabaseSettingsView: View {
    @EnvironmentObject private var session: DatabaseSession
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var defaultUserName = ""
    @State private var recycleBinEnabled = true
    @State private var historyMaxItems = 10
    @State private var historyMaxSizeMiB = 6
    @State private var security = SecurityDraft()
    @State private var originalSecurity = SecurityDraft()
    @State private var loaded = false
    @State private var isSaving = false
    @State private var showChangeKey = false
    @State private var confirmEmptyBin = false

    private var db: Database { session.database }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("General") {
                        TextField("Database name", text: $name)
                        TextField("Description", text: $descriptionText, axis: .vertical)
                        TextField("Default username", text: $defaultUserName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section {
                        Toggle("Use Recycle Bin", isOn: $recycleBinEnabled)
                        if db.recycleBin != nil {
                            Button("Empty Recycle Bin", role: .destructive) { confirmEmptyBin = true }
                        }
                    } header: {
                        Text("Recycle Bin")
                    } footer: {
                        Text("Deleted items are moved to the Recycle Bin first and can be restored.")
                    }

                    Section("History") {
                        Stepper("Keep \(historyMaxItems) versions per entry", value: $historyMaxItems, in: 0...100)
                        Stepper("Max \(historyMaxSizeMiB) MiB per entry", value: $historyMaxSizeMiB, in: 1...100)
                    }

                    SecuritySettingsSection(draft: $security)

                    Section("Master key") {
                        Button("Change master key…") { showChangeKey = true }
                    }

                    Section("Information") {
                        InfoRow(label: "File", value: session.reference.fileName)
                        InfoRow(label: "Format", value: db.settings.versionString)
                        InfoRow(label: "Entries", value: "\(db.allEntries.count)")
                        InfoRow(label: "Groups", value: "\(db.allGroups.count - 1)")
                        InfoRow(label: "Master key changed", value: db.meta.masterKeyChanged.formatted(date: .abbreviated, time: .omitted))
                        if !db.meta.customIcons.isEmpty {
                            Button("Remove unused custom icons") {
                                db.pruneUnusedCustomIcons()
                                session.commit()
                            }
                        }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .disabled(session.isReadOnly || isSaving)
            .navigationTitle("Database settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save).bold().disabled(session.isReadOnly)
                    }
                }
            }
            .sheet(isPresented: $showChangeKey) {
                ChangeMasterKeyView().environmentObject(session)
            }
            .confirmationDialog("Empty the Recycle Bin?", isPresented: $confirmEmptyBin, titleVisibility: .visible) {
                Button("Empty Recycle Bin", role: .destructive) {
                    db.emptyRecycleBin()
                    session.commit()
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = db.meta.databaseName
        descriptionText = db.meta.databaseDescription
        defaultUserName = db.meta.defaultUserName
        recycleBinEnabled = db.meta.recycleBinEnabled
        historyMaxItems = max(0, db.meta.historyMaxItems)
        historyMaxSizeMiB = max(1, db.meta.historyMaxSize / (1024 * 1024))
        security = SecurityDraft(settings: db.settings)
        originalSecurity = security
    }

    private func save() {
        let now = Date()
        let meta = db.meta
        if meta.databaseName != name { meta.databaseName = name; meta.databaseNameChanged = now }
        if meta.databaseDescription != descriptionText { meta.databaseDescription = descriptionText; meta.databaseDescriptionChanged = now }
        if meta.defaultUserName != defaultUserName { meta.defaultUserName = defaultUserName; meta.defaultUserNameChanged = now }
        if meta.recycleBinEnabled != recycleBinEnabled { meta.recycleBinEnabled = recycleBinEnabled; meta.recycleBinChanged = now }
        meta.historyMaxItems = historyMaxItems
        meta.historyMaxSize = historyMaxSizeMiB * 1024 * 1024
        meta.settingsChanged = now

        if security != originalSecurity {
            isSaving = true
            let newSettings = security.makeSettings(base: db.settings)
            Task {
                await session.updateSettings(newSettings)
                isSaving = false
                dismiss()
            }
        } else {
            session.commit()
            dismiss()
        }
    }
}

/// Lets the user set a new password and/or key file.
struct ChangeMasterKeyView: View {
    @EnvironmentObject private var session: DatabaseSession
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = ""
    @State private var keyFile = KeyFileChoice()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        SecureField("New password", text: $password)
                            .textContentType(.newPassword)
                        SecureField("Confirm password", text: $confirm)
                            .textContentType(.newPassword)
                        if !password.isEmpty {
                            StrengthBar(bits: PasswordStrength.estimateBits(password))
                        }
                    } header: {
                        Text("Password")
                    } footer: {
                        if !confirm.isEmpty && confirm != password {
                            Text("The passwords do not match.").foregroundStyle(.red)
                        }
                    }
                    KeyFileSection(choice: $keyFile)
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Change master key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Change", action: apply)
                            .bold()
                            .disabled(password != confirm || (password.isEmpty && keyFile.data == nil))
                    }
                }
            }
        }
    }

    private func apply() {
        do {
            let key = try CompositeKey(password: password.isEmpty ? nil : password, keyFileData: keyFile.data)
            isSaving = true
            Task {
                await session.changeMasterKey(to: key)
                isSaving = false
                ToastCenter.shared.show(String(localized: "Master key changed"))
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Key file selection: none, an existing file, or a newly generated one (which must be saved first).
struct KeyFileChoice {
    var data: Data?
    var name: String?
}

struct KeyFileSection: View {
    @Binding var choice: KeyFileChoice
    @State private var showPicker = false
    @State private var exportDocument: BinaryFileDocument?
    @State private var showExporter = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            HStack {
                Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary)
                Text(choice.name ?? String(localized: "No key file"))
                    .foregroundStyle(choice.name == nil ? .secondary : .primary)
                Spacer()
                if choice.name != nil {
                    Button {
                        choice = KeyFileChoice()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Use an existing key file") { showPicker = true }
                .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item]) { result in
                    guard case .success(let url) = result else { return }
                    do {
                        let data = try FileAccess.readPicked(url)
                        _ = try KeyFile.key(from: data)
                        choice = KeyFileChoice(data: data, name: url.lastPathComponent)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            Button("Generate a new key file…") {
                exportDocument = BinaryFileDocument(data: KeyFile.generate())
                showExporter = true
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .data,
                          defaultFilename: "SaveKey.keyx") { result in
                switch result {
                case .success(let url):
                    choice = KeyFileChoice(data: exportDocument?.data, name: url.lastPathComponent)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        } header: {
            Text("Key file (optional)")
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Text("A key file adds a second factor. Keep a backup: without it the database cannot be opened.")
            }
        }
    }
}

struct BinaryFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
