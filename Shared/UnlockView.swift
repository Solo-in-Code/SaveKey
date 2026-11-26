// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

/// Master password / key file / biometric unlock form. Used by the app and AutoFill.
struct UnlockView: View {
    let reference: DatabaseReference
    var forceReadOnly = false
    var onUnlocked: (DatabaseSession) -> Void

    @EnvironmentObject private var library: DatabaseLibrary
    @EnvironmentObject private var settings: AppSettings

    @State private var password = ""
    @State private var showPassword = false
    @State private var keyFileURL: URL?
    @State private var keyFileName: String?
    @State private var showImporter = false
    @State private var importTarget = ImportTarget.keyFile
    @State private var useBiometrics = false
    @State private var readOnly = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var hasBiometricKey = false
    @State private var didAppear = false
    /// The last error is fixed by choosing the folder that contains the database.
    @State private var needsFolder = false
    @FocusState private var passwordFocused: Bool

    /// What the (single) file importer is choosing.
    private enum ImportTarget { case keyFile, folder }

    /// The reference as stored now (it changes when a folder is chosen here).
    private var currentReference: DatabaseReference { library.reference(id: reference.id) ?? reference }

    var body: some View {
        Form {
            Group {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reference.name).font(.headline)
                            HStack(spacing: 4) {
                                Text(currentReference.fileName)
                                if let folder = currentReference.folderName, currentReference.followsFolder {
                                    Image(systemName: "folder")
                                    Text(folder)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Master key") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($passwordFocused)
                        .submitLabel(.go)
                        .onSubmit(unlock)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }

                    HStack {
                        Image(systemName: "doc.badge.gearshape")
                            .foregroundStyle(.secondary)
                        Text(keyFileName ?? String(localized: "No key file"))
                            .foregroundStyle(keyFileName == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if keyFileName != nil {
                            Button {
                                keyFileURL = nil
                                keyFileName = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove key file")
                        }
                        Button("Choose") { choose(.keyFile) }
                            .buttonStyle(.borderless)
                    }
                }

                Section {
                    if !forceReadOnly {
                        Toggle("Open read-only", isOn: $readOnly)
                    }
                    if BiometricKeyStore.isAvailable {
                        Toggle("Unlock with \(BiometricKeyStore.biometryName)", isOn: $useBiometrics)
                    }
                } footer: {
                    if BiometricKeyStore.isAvailable {
                        Text("When enabled, the derived key is stored in this device's Keychain, protected by \(BiometricKeyStore.biometryName).")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        if needsFolder {
                            if forceReadOnly {
                                Text("Open SaveKey to choose the folder.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button {
                                    choose(.folder)
                                } label: {
                                    Label("Choose folder…", systemImage: "folder")
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(action: unlock) {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                                Text("Unlocking…").padding(.leading, 6)
                            } else {
                                Text("Unlock").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking || (password.isEmpty && keyFileURL == nil))

                    if hasBiometricKey {
                        Button(action: unlockWithBiometrics) {
                            HStack {
                                Spacer()
                                Label("Unlock with \(BiometricKeyStore.biometryName)", systemImage: BiometricKeyStore.biometrySymbol)
                                Spacer()
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .themedRows()
        }
        .themedBackground()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTarget == .folder ? [.folder] : [.item]) { result in
            guard case .success(let url) = result else { return }
            if importTarget == .folder {
                followFolder(url)
            } else {
                keyFileURL = url
                keyFileName = url.lastPathComponent
            }
        }
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !didAppear else { return }
        didAppear = true
        readOnly = forceReadOnly || (currentReference.opensReadOnly ?? false)
        if settings.rememberKeyFiles, let url = reference.resolveKeyFileURL() {
            keyFileURL = url
            keyFileName = reference.keyFileName ?? url.lastPathComponent
        }
        hasBiometricKey = BiometricKeyStore.hasKey(for: reference.id)
        useBiometrics = hasBiometricKey
        if hasBiometricKey && settings.autoPromptBiometrics {
            unlockWithBiometrics()
        } else {
            passwordFocused = true
        }
    }

    private func unlock() {
        guard !isWorking, !(password.isEmpty && keyFileURL == nil) else { return }
        isWorking = true
        errorMessage = nil
        needsFolder = false
        let pw = password
        let keyURL = keyFileURL
        let ref = currentReference
        let ro = readOnly || forceReadOnly
        Task {
            do {
                var keyData: Data?
                if let keyURL {
                    keyData = try await Task.detached { try FileAccess.readPicked(keyURL) }.value
                }
                let session: DatabaseSession
                do {
                    let key = try CompositeKey(password: (pw.isEmpty && keyData != nil) ? nil : pw, keyFileData: keyData)
                    session = try await DatabaseSession.open(reference: ref, key: key, readOnly: ro)
                } catch KDBXError.invalidCredentials where pw.isEmpty && keyData != nil {
                    // Some apps include an empty password alongside the key file.
                    let key = try CompositeKey(password: "", keyFileData: keyData)
                    session = try await DatabaseSession.open(reference: ref, key: key, readOnly: ro)
                }
                if useBiometrics {
                    try? BiometricKeyStore.store(session.key.rawKey, for: ref.id)
                } else if hasBiometricKey {
                    BiometricKeyStore.delete(for: ref.id)
                }
                library.setKeyFile(settings.rememberKeyFiles ? keyURL : nil, for: ref)
                library.markOpened(ref)
                if !forceReadOnly { library.setOpensReadOnly(readOnly, for: ref) }
                password = ""
                isWorking = false
                onUnlocked(session)
            } catch {
                isWorking = false
                show(error)
                passwordFocused = true
            }
        }
    }

    private func unlockWithBiometrics() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        needsFolder = false
        let ref = currentReference
        let ro = readOnly || forceReadOnly
        Task {
            do {
                let raw = try await Task.detached {
                    try BiometricKeyStore.loadKey(for: ref.id, reason: String(localized: "Unlock “\(ref.name)”"))
                }.value
                let session = try await DatabaseSession.open(reference: ref, key: CompositeKey(rawKey: raw), readOnly: ro)
                library.markOpened(ref)
                if !forceReadOnly { library.setOpensReadOnly(readOnly, for: ref) }
                isWorking = false
                onUnlocked(session)
            } catch BiometricKeyStore.StoreError.cancelled {
                isWorking = false
                passwordFocused = true
            } catch KDBXError.invalidCredentials {
                BiometricKeyStore.delete(for: ref.id)
                hasBiometricKey = false
                useBiometrics = false
                isWorking = false
                errorMessage = String(localized: "The master key has changed. Unlock with your password to set up \(BiometricKeyStore.biometryName) again.")
            } catch BiometricKeyStore.StoreError.notFound {
                hasBiometricKey = false
                useBiometrics = false
                isWorking = false
                errorMessage = BiometricKeyStore.StoreError.notFound.localizedDescription
            } catch {
                isWorking = false
                show(error)
            }
        }
    }

    private func choose(_ target: ImportTarget) {
        importTarget = target
        showImporter = true
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        needsFolder = (error as? BookmarkError)?.isFixedByChoosingFolder ?? false
    }

    /// Follows the database by name inside the chosen folder, then unlocks if possible.
    private func followFolder(_ folder: URL) {
        let ref = currentReference
        let candidate = ScopedFile(url: folder.appendingPathComponent(ref.fileName, isDirectory: false), scope: folder)
        Task {
            let present = await Task.detached { FileAccess.exists(candidate) }.value
            guard present else {
                errorMessage = BookmarkError.notInFolder(file: ref.fileName, folder: folder.lastPathComponent).localizedDescription
                needsFolder = true
                return
            }
            do {
                try library.follow(ref, inFolder: folder, fileName: ref.fileName)
                errorMessage = nil
                needsFolder = false
                if !password.isEmpty || keyFileURL != nil {
                    unlock()
                } else if hasBiometricKey {
                    unlockWithBiometrics()
                } else {
                    passwordFocused = true
                }
            } catch {
                show(error)
            }
        }
    }
}

/// A row showing an entry's icon, title and username (card details for cards, the date for notes).
struct EntryRow: View {
    let entry: KPEntry
    var customIcon: CustomIcon?
    var showPath = false
    /// The entry is a secure note (stored in the Notes folder).
    var isNote = false
    /// Captured so the row refreshes after the entry is edited (entries are reference types).
    private let revision: Int

    init(entry: KPEntry, customIcon: CustomIcon? = nil, showPath: Bool = false, isNote: Bool = false) {
        self.entry = entry
        self.customIcon = customIcon
        self.showPath = showPath
        self.isNote = isNote
        self.revision = entry.displayRevision
    }

    var body: some View {
        let card = PaymentCard.from(entry: entry)
        HStack(spacing: 12) {
            EntryIconView(entry: entry, customIcon: customIcon, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
                    .font(.body)
                    .strikethrough(entry.times.isExpired)
                    .lineLimit(1)
                let subtitle = subtitleText(card: card)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if OTPConfig.from(entry: entry) != nil {
                Image(systemName: "clock.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has one-time code")
            }
            if card == nil && !entry.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitleText(card: PaymentCard?) -> String {
        var primary = entry.userName
        if let card {
            primary = card.number.isEmpty ? card.brandName : "\(card.brandName.isEmpty ? String(localized: "Card") : card.brandName) •••• \(card.last4)"
            if let expiry = card.expiry { primary += " · \(expiry.shortString)" }
        } else if isNote && primary.isEmpty {
            // The note's text stays private in the list; show when it was last edited instead.
            primary = entry.times.lastModification.formatted(date: .abbreviated, time: .omitted)
        }
        guard showPath && !entry.path.isEmpty else { return primary }
        return primary.isEmpty ? entry.path : "\(primary) · \(entry.path)"
    }
}
