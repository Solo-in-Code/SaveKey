// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import QuickLook
import KeePassCore

struct EntryDetailView: View {
    let entry: KPEntry
    /// Set when showing an old version from the entry's history.
    var historyOwner: KPEntry?

    @EnvironmentObject private var session: DatabaseSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var showPassword = false
    @State private var revealedFields: Set<String> = []
    @State private var editing = false
    @State private var editingCard = false
    @State private var revealCardNumber = false
    @State private var moving: MoveItem?
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var attachmentError: String?

    private var isHistory: Bool { historyOwner != nil }
    private var canEdit: Bool { !session.isReadOnly && !isHistory }
    private var card: PaymentCard? { PaymentCard.from(entry: entry) }
    /// Entries in the Notes folder are shown as notes: the note first, no empty credentials or one-time password.
    private var isNote: Bool { card == nil && NotesFolder.contains(historyOwner ?? entry, in: session.database) }
    /// "Card", "Note" or "Entry" (used as the title of an untitled item).
    private var kindName: String {
        card != nil ? String(localized: "Card") : (isNote ? String(localized: "Note") : String(localized: "Entry"))
    }

    private var expiredMessage: String {
        let date = entry.times.expiry.formatted(date: .abbreviated, time: .omitted)
        if card != nil { return String(localized: "This card expired \(date).") }
        if isNote { return String(localized: "This note expired \(date).") }
        return String(localized: "This entry expired \(date).")
    }

    private var deleteQuestion: String {
        if card != nil { return String(localized: "Delete this card?") }
        if isNote { return String(localized: "Delete this note?") }
        return String(localized: "Delete this entry?")
    }

    var body: some View {
        List {
            Group {
                header
                if entry.times.isExpired {
                    Section {
                        Label(expiredMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .themedRows()
            if let card {
                CardPreviewSection(card: card, title: entry.title, revealNumber: $revealCardNumber)
            }
            Group {
                if let card {
                    CardDetailSections(entry: entry, card: card, revealNumber: $revealCardNumber) { attachment in
                        previewURL = writeTemp(attachment)
                    }
                }
                credentialsAndMore
            }
            .themedRows()
        }
        .themedBackground()
        .listStyle(.insetGrouped)
        .navigationTitle(isHistory ? String(localized: "Previous version") : (entry.title.isEmpty ? kindName : entry.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { showPassword = settings.showPasswordsByDefault }
        .sheet(isPresented: $editing) {
            EntryEditView(mode: .edit(entry), isNote: isNote)
                .environmentObject(session)
                .environmentObject(settings)
        }
        .sheet(isPresented: $editingCard) {
            CardEditView(mode: .edit(entry))
                .environmentObject(session)
        }
        .sheet(item: $moving) { item in
            MoveView(item: item).environmentObject(session)
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ActivityView(items: [item.url])
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(deleteQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(session.database.meta.recycleBinEnabled && !session.database.isInRecycleBin(entry)
                   ? "Move to Recycle Bin" : "Delete permanently", role: .destructive) {
                session.database.delete(entry)
                session.commit()
                dismiss()
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { restoreHistory() }
        } message: {
            Text("The current version is kept in the history.")
        }
        .alert("Attachment", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
    }

    @ViewBuilder private var credentialsAndMore: some View {
            if isNote { noteSection }
            credentials
            if let otp = OTPConfig.from(entry: entry) {
                Section("One-time password") {
                    OTPCodeView(config: otp, onAdvance: canEdit ? { advanceHOTP(otp) } : nil)
                }
            }
            customFields
            if !isNote && !entry.notes.isEmpty {
                Section("Notes") {
                    Text(entry.notes)
                        .textSelection(.enabled)
                        .font(.callout)
                        .contextMenu {
                            Button { ToastCenter.shared.copied(entry.notes, label: String(localized: "Notes"), sensitive: false) } label: {
                                Label("Copy notes", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
            attachments
            details
    }

    // MARK: Sections

    /// The note itself, shown first for entries in the Notes folder.
    private var noteSection: some View {
        Section("Note") {
            if entry.notes.isEmpty {
                Text("This note is empty.")
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                Button {
                    ToastCenter.shared.copied(entry.notes, label: String(localized: "Note"))
                } label: {
                    Label("Copy note", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                EntryIconView(entry: entry, customIcon: session.customIcon(entry.customIconUUID), size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    if !entry.path.isEmpty {
                        Label(entry.path, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(entry.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var credentials: some View {
        let hasAny = !entry.userName.isEmpty || !entry.password.isEmpty || !entry.url.isEmpty
        if hasAny {
            Section {
                if !entry.userName.isEmpty {
                    FieldRow(label: String(localized: "Username"), value: entry.userName) {
                        ToastCenter.shared.copied(entry.userName, label: String(localized: "Username"), sensitive: false)
                    }
                }
                if !entry.password.isEmpty {
                    PasswordFieldRow(label: String(localized: "Password"), value: entry.password, isRevealed: $showPassword,
                                     showStrength: true) {
                        ToastCenter.shared.copied(entry.password, label: String(localized: "Password"))
                    }
                }
                if !entry.url.isEmpty {
                    FieldRow(label: String(localized: "URL"), value: entry.url, valueColor: .accentColor) {
                        ToastCenter.shared.copied(entry.url, label: String(localized: "URL"), sensitive: false)
                    } trailing: {
                        if let url = openableURL(entry.url) {
                            Button {
                                openURL(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Open in browser")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var customFields: some View {
        let cardKeys = card?.fieldKeys ?? []
        let fields = entry.customFields.filter { !OTPConfig.isOTPField($0.key) && !cardKeys.contains($0.key) }
        if !fields.isEmpty {
            Section("Fields") {
                ForEach(fields) { field in
                    if field.isProtected {
                        PasswordFieldRow(label: field.key, value: field.value,
                                         isRevealed: Binding(get: { revealedFields.contains(field.key) },
                                                             set: { if $0 { revealedFields.insert(field.key) } else { revealedFields.remove(field.key) } })) {
                            ToastCenter.shared.copied(field.value, label: field.key)
                        }
                    } else {
                        FieldRow(label: field.key, value: field.value) {
                            ToastCenter.shared.copied(field.value, label: field.key, sensitive: false)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var attachments: some View {
        let files = card == nil ? entry.attachments : entry.attachments.filter { !CardImages.names.contains($0.name) }
        if !files.isEmpty {
            Section("Attachments") {
                ForEach(files) { a in
                    HStack {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(a.name).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            shareURL = writeTemp(a)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Share \(a.name)")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { previewURL = writeTemp(a) }
                }
            }
        }
    }

    private var details: some View {
        Section("Details") {
            InfoRow(label: "Created", value: entry.times.creation.formatted(date: .abbreviated, time: .shortened))
            InfoRow(label: "Modified", value: entry.times.lastModification.formatted(date: .abbreviated, time: .shortened))
            if entry.times.expires {
                InfoRow(label: "Expires", value: entry.times.expiry.formatted(date: .abbreviated, time: .shortened))
            }
            if !isHistory && !entry.history.isEmpty {
                NavigationLink {
                    HistoryListView(entry: entry)
                } label: {
                    HStack {
                        Text("History")
                        Spacer()
                        Text("\(entry.history.count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isHistory && !session.isReadOnly {
                Button("Restore") { confirmRestore = true }
            }
            if canEdit {
                Button("Edit") {
                    if card != nil { editingCard = true } else { editing = true }
                }
                Menu {
                    if card != nil {
                        Button { editing = true } label: { Label("Edit all fields", systemImage: "list.bullet.rectangle") }
                    }
                    Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { moving = .entry(entry) } label: { Label("Move…", systemImage: "folder") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Actions

    private func openableURL(_ s: String) -> URL? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), let scheme = u.scheme, ["http", "https"].contains(scheme.lowercased()) { return u }
        if !trimmed.contains("://"), trimmed.contains("."), let u = URL(string: "https://" + trimmed) { return u }
        return nil
    }

    private func writeTemp(_ a: Attachment) -> URL? {
        do {
            return try TemporaryFiles.write(a.data, name: a.name)
        } catch {
            attachmentError = error.localizedDescription
            return nil
        }
    }

    private func advanceHOTP(_ otp: OTPConfig) {
        let (maxItems, maxSize) = session.historyLimits()
        entry.backupToHistory(maxItems: maxItems, maxSize: maxSize)
        otp.advanced().apply(to: entry)
        entry.times.touch(modified: true)
        session.commit()
    }

    private func duplicate() {
        guard let parent = entry.parent else { return }
        let copy = entry.copy(includeHistory: false)
        let dup = KPEntry()
        dup.restore(from: copy)
        dup.title = String(localized: "\(entry.title) (copy)")
        parent.add(dup)
        session.commit()
        ToastCenter.shared.show(String(localized: "Entry duplicated"))
    }

    private func restoreHistory() {
        guard let owner = historyOwner else { return }
        let (maxItems, maxSize) = session.historyLimits()
        owner.backupToHistory(maxItems: maxItems, maxSize: maxSize)
        owner.restore(from: entry)
        session.commit()
        dismiss()
        ToastCenter.shared.show(String(localized: "Version restored"))
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// UIActivityViewController wrapper (works on iOS 16 without Transferable conformance).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Rows

struct FieldRow<Trailing: View>: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var onCopy: () -> Void
    let trailing: () -> Trailing

    init(label: String, value: String, valueColor: Color = .primary, onCopy: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.onCopy = onCopy
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .foregroundStyle(valueColor)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            trailing()
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(label)")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
    }
}

extension FieldRow where Trailing == EmptyView {
    init(label: String, value: String, valueColor: Color = .primary, onCopy: @escaping () -> Void) {
        self.init(label: label, value: value, valueColor: valueColor, onCopy: onCopy) { EmptyView() }
    }
}

struct PasswordFieldRow: View {
    let label: String
    let value: String
    @Binding var isRevealed: Bool
    var showStrength = false
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if isRevealed {
                        ColoredPasswordText(password: value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: min(max(value.count, 8), 16)))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Spacer()
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? "Hide \(label)" : "Show \(label)")
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(label)")
            }
            if showStrength {
                StrengthBar(bits: PasswordStrength.estimateBits(value))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
    }
}

struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// Live TOTP/Steam code with countdown ring; HOTP shows a "next" button.
struct OTPCodeView: View {
    let config: OTPConfig
    var onAdvance: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = config.code(at: context.date)
            HStack(spacing: 16) {
                Text(grouped(code))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(config.isTimeBased && config.remaining(at: context.date) <= 5 ? Color.red : Color.primary)
                Spacer()
                if config.isTimeBased {
                    let remaining = config.remaining(at: context.date)
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(config.period, 1)))
                            .stroke(remaining <= 5 ? Color.red : Color.accentColor,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: remaining)
                        Text("\(remaining)")
                            .font(.caption.monospacedDigit())
                    }
                    .frame(width: 34, height: 34)
                } else if let onAdvance {
                    Button("Next", action: onAdvance)
                        .buttonStyle(.bordered)
                }
                Button {
                    ToastCenter.shared.copied(config.code(), label: String(localized: "One-time code"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy one-time code")
            }
            .contentShape(Rectangle())
            .onTapGesture { ToastCenter.shared.copied(config.code(), label: String(localized: "One-time code")) }
        }
        .padding(.vertical, 4)
    }

    private func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return String(code[..<mid]) + " " + String(code[mid...])
    }
}

/// Shows the password with digits and symbols colour-coded, like KeePassDX.
struct ColoredPasswordText: View {
    let password: String

    var body: some View {
        password.reduce(Text("")) { text, ch in
            let color: Color
            if ch.isNumber {
                color = .blue
            } else if ch.isLetter {
                color = .primary
            } else {
                color = .red
            }
            return text + Text(String(ch)).foregroundColor(color)
        }
    }
}

struct StrengthBar: View {
    let bits: Double

    private var strength: PasswordStrength { PasswordStrength(bits: bits) }
    private var color: Color {
        switch strength {
        case .veryWeak: return .red
        case .weak: return .orange
        case .fair: return .yellow
        case .strong: return .green
        case .veryStrong: return .mint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(min(bits / 128, 1)))
                }
            }
            .frame(height: 5)
            Text("\(strength.label) · \(Int(bits)) bits")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct HistoryListView: View {
    let entry: KPEntry
    @EnvironmentObject private var session: DatabaseSession

    var body: some View {
        List {
            Group {
                ForEach(Array(entry.history.enumerated().reversed()), id: \.offset) { _, old in
                    NavigationLink {
                        EntryDetailView(entry: old, historyOwner: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(old.title.isEmpty ? String(localized: "(untitled)") : old.title)
                            Text(old.times.lastModification.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: session.isReadOnly ? nil : deleteVersions)
            }
            .themedRows()
        }
        .themedBackground()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deleteVersions(_ offsets: IndexSet) {
        // Offsets refer to the reversed (newest first) list.
        let count = entry.history.count
        for i in offsets.map({ count - 1 - $0 }).sorted(by: >) {
            entry.history.remove(at: i)
        }
        session.commit()
    }
}
