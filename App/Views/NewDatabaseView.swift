// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

struct NewDatabaseView: View {
    var onCreated: (DatabaseSession) -> Void

    @EnvironmentObject private var library: DatabaseLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var name = String(localized: "Passwords")
    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false
    @State private var keyFile = KeyFileChoice()
    @State private var security = SecurityDraft()
    @State private var showAdvanced = false
    @State private var useBiometrics = BiometricKeyStore.isAvailable

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var document: BinaryFileDocument?
    @State private var showExporter = false
    @State private var pending: (Database, CompositeKey, Data)?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && password == confirm &&
            (!password.isEmpty || keyFile.data != nil) && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("Name") {
                        TextField("Database name", text: $name)
                    }
                    Section {
                        HStack {
                            Group {
                                if showPassword {
                                    TextField("Master password", text: $password)
                                } else {
                                    SecureField("Master password", text: $password)
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
                        }
                        SecureField("Confirm password", text: $confirm)
                            .textContentType(.newPassword)
                        if !password.isEmpty {
                            StrengthBar(bits: PasswordStrength.estimateBits(password))
                        }
                    } header: {
                        Text("Master password")
                    } footer: {
                        if !confirm.isEmpty && confirm != password {
                            Text("The passwords do not match.").foregroundStyle(.red)
                        } else {
                            Text("There is no way to recover a forgotten master password. Choose something long and memorable — a passphrase works well.")
                        }
                    }

                    KeyFileSection(choice: $keyFile)

                    if BiometricKeyStore.isAvailable {
                        Section {
                            Toggle("Unlock with \(BiometricKeyStore.biometryName)", isOn: $useBiometrics)
                        }
                    }

                    Section {
                        Toggle("Customize encryption", isOn: $showAdvanced.animation())
                    } footer: {
                        if !showAdvanced { Text("Default: AES-256 with Argon2id (64 MiB, 4 iterations).") }
                    }
                    if showAdvanced {
                        SecuritySettingsSection(draft: $security)
                    }

                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("New database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Create", action: create).bold().disabled(!canCreate)
                    }
                }
            }
            .fileExporter(isPresented: $showExporter, document: document, contentType: .kdbx,
                          defaultFilename: fileName) { result in
                switch result {
                case .success(let url): finish(url: url)
                case .failure(let error):
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: showExporter) { presented in
                // Exporter dismissed without choosing a location.
                guard !presented, isWorking else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if pending != nil && !showExporter { isWorking = false }
                }
            }
        }
    }

    private var fileName: String {
        let base = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return (base.isEmpty ? String(localized: "Passwords") : base) + ".kdbx"
    }

    private func create() {
        errorMessage = nil
        isWorking = true
        let dbName = name.trimmingCharacters(in: .whitespaces)
        let settings = security.makeSettings(base: nil)
        let pw = password
        let kf = keyFile.data
        // Starter folders and the sample entry use the app's language.
        let groups: [(name: String, iconID: Int)] = [
            (String(localized: "General"), 48), (String(localized: "Email"), 19), (String(localized: "Internet"), 1),
            (CardFolder.defaultName, 37), (NotesFolder.defaultName, NotesFolder.iconID),
        ]
        let sampleTitle = String(localized: "Sample entry")
        let sampleNotes = String(localized: "You can delete this entry.")
        Task {
            do {
                let key = try CompositeKey(password: pw.isEmpty ? nil : pw, keyFileData: kf)
                let (db, data) = try await Task.detached(priority: .userInitiated) { () throws -> (Database, Data) in
                    let db = Database.create(name: dbName, settings: settings, groups: groups)
                    let internet = db.root.groups.first(where: { $0.iconID == 1 }) ?? db.root
                    let sample = db.createEntry(in: internet)
                    sample.title = sampleTitle
                    sample.userName = "user@example.com"
                    sample.password = PasswordGenerator.generate(PasswordOptions())
                    sample.url = "https://keepass.info"
                    sample.notes = sampleNotes
                    return (db, try KDBX.save(db, key: key))
                }.value
                pending = (db, key, Hash.sha256(data))
                document = BinaryFileDocument(data: data)
                showExporter = true
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finish(url: URL) {
        guard let created = pending else { return }
        let (db, key, hash) = created
        pending = nil
        do {
            let ref = try library.add(url: url)
            if useBiometrics { try? BiometricKeyStore.store(key.rawKey, for: ref.id) }
            library.markOpened(ref)
            let file = try ref.resolve().file
            let session = DatabaseSession(reference: ref, file: file, database: db, key: key,
                                          fileState: FileAccess.state(file), fileHash: hash, readOnly: false)
            isWorking = false
            onCreated(session)
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }
}
