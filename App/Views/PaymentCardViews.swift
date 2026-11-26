// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI
import Vision
import VisionKit
import KeePassCore

// MARK: - Banking folder

/// Where new cards are stored: the database's banking group (created on first use).
enum CardFolder {
    /// Folder names recognised as the Banking folder, in all of SaveKey's languages.
    static let names: Set<String> = [
        "banking", "homebanking", "home banking", "bank", "banks", "banco", "bancos", "finance", "finances",
        "finanças", "financas", "cards", "cartões", "cartoes", "banken", "finanzen", "karten", "banca",
        "banche", "finanza", "carte", "banque", "banques", "cartes", "finanzas", "tarjetas",
    ]
    /// Name given to the folder when SaveKey creates it, in the app's language.
    static var defaultName: String { String(localized: "Banking") }

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
        group.iconID = 37
        return group
    }

    /// True if `group` is the banking group or inside it.
    static func contains(_ group: KPGroup, in db: Database) -> Bool {
        guard let banking = find(in: db) else { return false }
        return group === banking || group.isDescendant(of: banking)
    }
}

// MARK: - Card visual

struct PaymentCardView: View {
    let card: PaymentCard
    var title = ""
    var revealNumber = false

    var body: some View {
        let brand = card.resolvedBrand
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CardStyle.gradient(for: brand))
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 240, height: 240)
                .offset(x: 130, y: -80)
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 180, height: 180)
                .offset(x: -140, y: 95)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(title.isEmpty ? " " : title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(card.brandName.isEmpty ? String(localized: "CARD") : card.brandName.uppercased())
                        .font(.system(size: 17, weight: .heavy))
                        .italic()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 6)
                HStack(spacing: 10) {
                    CardChip()
                        .frame(width: 42, height: 31)
                    Image(systemName: "wave.3.right")
                        .font(.title3.weight(.semibold))
                        .opacity(0.85)
                }
                Spacer(minLength: 6)
                Text(numberText)
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 6)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CARD HOLDER")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.7)
                        Text(card.holder.isEmpty ? "—" : card.holder.uppercased())
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("VALID THRU")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.7)
                        Text(card.expiry?.shortString ?? String(localized: "MM/YY"))
                            .font(.footnote.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .padding(18)
        }
        .foregroundStyle(.white)
        .aspectRatio(1.586, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.brandName.isEmpty ? String(localized: "Card") : card.brandName) ending in \(card.last4)")
    }

    private var numberText: String {
        guard !card.number.isEmpty else { return "•••• •••• •••• ••••" }
        if revealNumber { return card.formattedNumber }
        let groups = card.formattedNumber.split(separator: " ").map(String.init)
        return groups.enumerated().map { index, group in
            index == groups.count - 1 ? group : String(repeating: "•", count: group.count)
        }.joined(separator: " ")
    }
}

struct CardChip: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.97, green: 0.87, blue: 0.56), Color(red: 0.78, green: 0.62, blue: 0.29)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                GeometryReader { geo in
                    Path { p in
                        let w = geo.size.width
                        let h = geo.size.height
                        p.move(to: CGPoint(x: w * 0.33, y: 0)); p.addLine(to: CGPoint(x: w * 0.33, y: h))
                        p.move(to: CGPoint(x: w * 0.67, y: 0)); p.addLine(to: CGPoint(x: w * 0.67, y: h))
                        p.move(to: CGPoint(x: 0, y: h * 0.5)); p.addLine(to: CGPoint(x: w, y: h * 0.5))
                    }
                    .stroke(Color.black.opacity(0.22), lineWidth: 1)
                }
            )
    }
}

// MARK: - Card details on the entry screen

/// The card picture at the top of a card entry (tap to show or hide the number).
struct CardPreviewSection: View {
    let card: PaymentCard
    let title: String
    @Binding var revealNumber: Bool

    var body: some View {
        Section {
            PaymentCardView(card: card, title: title, revealNumber: revealNumber)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { revealNumber.toggle() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        } footer: {
            Text("Tap the card to show or hide the number.")
        }
    }
}

struct CardDetailSections: View {
    let entry: KPEntry
    let card: PaymentCard
    @Binding var revealNumber: Bool
    var onPreview: (Attachment) -> Void

    @State private var revealCVV = false
    @State private var revealPIN = false

    var body: some View {
        Section("Card details") {
            if !card.number.isEmpty {
                PasswordFieldRow(label: String(localized: "Card number"), value: card.formattedNumber, isRevealed: $revealNumber) {
                    ToastCenter.shared.copied(card.number, label: String(localized: "Card number"))
                }
                if !card.isNumberValid {
                    Label("This number doesn't pass the card checksum.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if !card.holder.isEmpty {
                FieldRow(label: String(localized: "Name of card owner"), value: card.holder) {
                    ToastCenter.shared.copied(card.holder, label: String(localized: "Name"), sensitive: false)
                }
            }
            if !card.brandName.isEmpty {
                InfoRow(label: "Card brand", value: card.brandName)
            }
            if let expiry = card.expiry {
                FieldRow(label: expiry.isExpired() ? String(localized: "Valid thru (expired)") : String(localized: "Valid thru"), value: expiry.shortString,
                         valueColor: expiry.isExpired() ? .red : .primary) {
                    ToastCenter.shared.copied(expiry.shortString, label: String(localized: "Expiry date"), sensitive: false)
                }
            }
            if !card.cvv.isEmpty {
                PasswordFieldRow(label: String(localized: "Security code (CVV)"), value: card.cvv, isRevealed: $revealCVV) {
                    ToastCenter.shared.copied(card.cvv, label: String(localized: "Security code"))
                }
            }
            if !card.pin.isEmpty {
                PasswordFieldRow(label: String(localized: "PIN"), value: card.pin, isRevealed: $revealPIN) {
                    ToastCenter.shared.copied(card.pin, label: String(localized: "PIN"))
                }
            }
        }

        let images = CardImages.attachments(of: entry)
        if !images.isEmpty {
            Section("Card images") {
                HStack(spacing: 12) {
                    ForEach(images) { attachment in
                        if let image = UIImage(data: attachment.data) {
                            Button {
                                onPreview(attachment)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Text(attachment.name == PaymentCard.frontImageName ? "Front" : "Back")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

enum CardImages {
    static let names: Set<String> = [PaymentCard.frontImageName, PaymentCard.backImageName]

    static func attachments(of entry: KPEntry) -> [Attachment] {
        entry.attachments
            .filter { names.contains($0.name) }
            .sorted { $0.name == PaymentCard.frontImageName && $1.name != PaymentCard.frontImageName }
    }
}

// MARK: - Card editor

struct CardEditView: View {
    enum Mode {
        /// `nil` stores the card in the Banking folder (created if needed).
        case create(KPGroup?)
        case edit(KPEntry)
    }

    let mode: Mode
    @EnvironmentObject private var session: DatabaseSession
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var holder = ""
    @State private var numberText = ""
    @State private var brandChoice = ""
    @State private var expMonth = 0
    @State private var expYear = 0
    @State private var cvv = ""
    @State private var pin = ""
    @State private var notes = ""
    @State private var baseCard = PaymentCard()

    @State private var showCVV = false
    @State private var revealPreview = true
    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?
    @State private var imagesChanged = false
    @State private var keepImages = true
    @State private var showScanner = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isReading = false
    @State private var scanMessage: String?
    @State private var errorMessage: String?
    @State private var loaded = false

    private var isNew: Bool {
        if case .create = mode { return true }
        return false
    }

    private var digits: String { PaymentCard.digits(numberText) }

    private var draftCard: PaymentCard {
        var card = baseCard
        card.holder = holder.trimmingCharacters(in: .whitespaces)
        card.number = digits
        card.brand = brandChoice
        card.expiry = (expMonth > 0 && expYear > 0) ? CardExpiry(month: expMonth, year: expYear) : nil
        card.cvv = cvv
        card.pin = pin
        return card
    }

    private var yearOptions: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        var years = Array((current - 10)...(current + 20))
        if expYear > 0 && !years.contains(expYear) { years.append(expYear); years.sort() }
        return years
    }

    private var autoBrandLabel: String {
        if let detected = CardBrand.detect(digits) { return String(localized: "Automatic (\(detected.rawValue))") }
        return String(localized: "Automatic")
    }

    private var targetFolderName: String {
        if case .create(let group?) = mode { return group.name }
        return CardFolder.find(in: session.database)?.name ?? CardFolder.defaultName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PaymentCardView(card: draftCard, title: title, revealNumber: revealPreview)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { revealPreview.toggle() }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }

                Group {
                    digitizeSection
                    detailsSection

                    Section("Notes") {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                    }

                    if isNew {
                        Section {
                            Label("Saved in “\(targetFolderName)”", systemImage: "folder")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle(isNew ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .bold()
                        .disabled(digits.isEmpty && title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: numberText) { newValue in
                let formatted = PaymentCard.format(newValue, brand: CardBrand(rawValue: brandChoice))
                if formatted != newValue { numberText = formatted }
            }
            .onChange(of: brandChoice) { _ in
                numberText = PaymentCard.format(numberText, brand: CardBrand(rawValue: brandChoice))
            }
            .onChange(of: cvv) { newValue in
                let cleaned = String(PaymentCard.digits(newValue).prefix(4))
                if cleaned != newValue { cvv = cleaned }
            }
            .onChange(of: pin) { newValue in
                let cleaned = String(PaymentCard.digits(newValue).prefix(12))
                if cleaned != newValue { pin = cleaned }
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { images in
                    showScanner = false
                    Task { await read(images) }
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .alert("Card scanner", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
            .pausesFileSync(session)
        }
    }

    // MARK: Sections

    private var digitizeSection: some View {
        Section {
            Button {
                if VNDocumentCameraViewController.isSupported {
                    showScanner = true
                } else {
                    errorMessage = String(localized: "The camera scanner isn't available on this device. Use photos of the card instead.")
                }
            } label: {
                Label("Scan card with camera", systemImage: "camera.viewfinder")
            }
            .disabled(isReading)

            PhotosPicker(selection: $photoItems, maxSelectionCount: 2, matching: .images) {
                Label("Use photos of the card", systemImage: "photo.on.rectangle")
            }
            .disabled(isReading)

            if isReading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading card…").foregroundStyle(.secondary)
                }
            }

            if frontImage != nil || backImage != nil {
                HStack(spacing: 12) {
                    if let frontImage {
                        CardImageThumb(image: frontImage, isFront: true) {
                            self.frontImage = nil
                            imagesChanged = true
                        }
                    }
                    if let backImage {
                        CardImageThumb(image: backImage, isFront: false) {
                            self.backImage = nil
                            imagesChanged = true
                        }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Save card images in the entry", isOn: $keepImages)
            }
        } header: {
            Text("Digitize card")
        } footer: {
            Text(scanMessage ?? String(localized: "Scan the front of the card, then the back. The card is read on this iPhone — nothing is uploaded. Check the details before saving."))
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Card name (e.g. Bank Visa)", text: $title)

            TextField("Name of card owner", text: $holder)
                .textContentType(.name)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            HStack {
                TextField("Card number", text: $numberText)
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                    .font(.system(.body, design: .monospaced))
                if !digits.isEmpty {
                    Image(systemName: draftCard.isNumberValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(draftCard.isNumberValid ? Color.green : Color.orange)
                        .accessibilityLabel(draftCard.isNumberValid ? "Valid card number" : "Check the card number")
                }
            }

            Picker("Card brand", selection: $brandChoice) {
                Text(autoBrandLabel).tag("")
                ForEach(CardBrand.allCases) { brand in
                    Text(brand.rawValue).tag(brand.rawValue)
                }
                if !brandChoice.isEmpty && CardBrand(rawValue: brandChoice) == nil {
                    Text(brandChoice).tag(brandChoice)
                }
            }

            HStack {
                Text("Valid thru")
                Spacer()
                Picker("Month", selection: $expMonth) {
                    Text("MM").tag(0)
                    ForEach(1...12, id: \.self) { month in
                        Text(String(format: "%02d", month)).tag(month)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("/").foregroundStyle(.secondary)
                Picker("Year", selection: $expYear) {
                    Text("YYYY").tag(0)
                    ForEach(yearOptions, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                Group {
                    if showCVV {
                        TextField("Security code (CVV)", text: $cvv)
                    } else {
                        SecureField("Security code (CVV)", text: $cvv)
                    }
                }
                .keyboardType(.numberPad)
                .font(.system(.body, design: .monospaced))
                Button {
                    showCVV.toggle()
                } label: {
                    Image(systemName: showCVV ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showCVV ? "Hide security code" : "Show security code")
            }

            SecureField("PIN (optional)", text: $pin)
                .keyboardType(.numberPad)
        } header: {
            Text("Card details")
        } footer: {
            if !digits.isEmpty && !draftCard.isNumberValid {
                Text("This card number doesn't pass the card checksum — check for a typo or a misread digit.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Loading

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard case .edit(let entry) = mode else { return }
        revealPreview = false
        title = entry.title
        notes = entry.notes
        if let card = PaymentCard.from(entry: entry) {
            baseCard = card
            holder = card.holder
            numberText = card.formattedNumber
            brandChoice = (card.brand.isEmpty || card.brand == card.detectedBrand?.rawValue) ? "" : card.brand
            if let expiry = card.expiry {
                expMonth = expiry.month
                expYear = expiry.year
            }
            cvv = card.cvv
            pin = card.pin
        }
        for attachment in CardImages.attachments(of: entry) {
            if attachment.name == PaymentCard.frontImageName {
                frontImage = UIImage(data: attachment.data)
            } else {
                backImage = UIImage(data: attachment.data)
            }
        }
    }

    // MARK: Scanning

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoItems = []
        if images.isEmpty {
            errorMessage = String(localized: "The photos could not be loaded.")
        } else {
            await read(images)
        }
    }

    private func read(_ images: [UIImage]) async {
        guard var front = images.first else { return }
        var back: UIImage? = images.count > 1 ? images[1] : nil
        isReading = true
        scanMessage = nil

        var frontLines = await CardTextRecognizer.lines(in: front)
        var backLines: [CardTextParser.Line] = []
        if let back { backLines = await CardTextRecognizer.lines(in: back) }

        // If the back was scanned first, swap the two sides.
        if let originalBack = back,
           CardTextParser.parse(front: frontLines).number == nil,
           CardTextParser.parse(front: backLines).number != nil {
            swap(&frontLines, &backLines)
            back = front
            front = originalBack
        }
        let result = CardTextParser.parse(front: frontLines, back: backLines)

        if let number = result.number { numberText = PaymentCard.format(number) }
        if let name = result.holder { holder = name }
        if let expiry = result.expiry {
            expMonth = expiry.month
            expYear = expiry.year
        }
        if let code = result.cvv { cvv = code }
        if result.number == nil, brandChoice.isEmpty, let brand = result.brand { brandChoice = brand.rawValue }

        frontImage = front.resizedToFit(maxSide: 1400)
        if let back { backImage = back.resizedToFit(maxSide: 1400) }
        imagesChanged = true
        revealPreview = true
        isReading = false
        scanMessage = summary(of: result)
    }

    private func summary(of result: CardTextParser.Result) -> String {
        var found: [String] = []
        var missing: [String] = []
        func note(_ isFound: Bool, _ name: String) {
            if isFound { found.append(name) } else { missing.append(name) }
        }
        note(result.number != nil, String(localized: "card number"))
        note(result.holder != nil, String(localized: "name"))
        note(result.expiry != nil, String(localized: "valid thru"))
        note(result.cvv != nil, String(localized: "security code"))
        guard !found.isEmpty else {
            return String(localized: "The card couldn't be read. Try again in good light on a dark background, or type the details.")
        }
        // Lists are joined the way the app's language does it ("a, b and c").
        var parts = [String(localized: "Read: \(ListFormatter.localizedString(byJoining: found)).")]
        if !missing.isEmpty {
            parts.append(String(localized: "Not found: \(ListFormatter.localizedString(byJoining: missing))."))
        }
        parts.append(String(localized: "Please check the details before saving."))
        return parts.joined(separator: " ")
    }

    // MARK: Saving

    private func save() {
        let db = session.database
        let card = draftCard
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let finalTitle = trimmedTitle.isEmpty ? card.defaultTitle : trimmedTitle

        switch mode {
        case .create(let group):
            let target = group ?? CardFolder.findOrCreate(in: db)
            let entry = db.createEntry(in: target)
            entry.iconID = 37
            entry.userName = ""
            card.apply(to: entry)
            entry.title = finalTitle
            entry.notes = notes
            updateImageAttachments(entry)
            entry.times.touch(modified: true)
        case .edit(let entry):
            // Skip saving (and a history entry) if nothing changed.
            let preview = entry.copy(includeHistory: false)
            card.apply(to: preview)
            preview.title = finalTitle
            preview.notes = notes
            updateImageAttachments(preview)
            let unchanged = preview.fields == entry.fields && preview.attachments == entry.attachments &&
                preview.times.expires == entry.times.expires &&
                (!entry.times.expires || preview.times.expiry == entry.times.expiry)
            guard !unchanged else {
                dismiss()
                return
            }
            let (maxItems, maxSize) = session.historyLimits()
            entry.backupToHistory(maxItems: maxItems, maxSize: maxSize)
            card.apply(to: entry)
            entry.title = finalTitle
            entry.notes = notes
            updateImageAttachments(entry)
            entry.times.touch(modified: true)
        }
        session.commit()
        dismiss()
    }

    private func updateImageAttachments(_ entry: KPEntry) {
        if !keepImages {
            entry.attachments.removeAll { CardImages.names.contains($0.name) }
            return
        }
        guard imagesChanged else { return }
        entry.attachments.removeAll { CardImages.names.contains($0.name) }
        if let data = frontImage?.jpegData(compressionQuality: 0.75) {
            entry.attachments.append(Attachment(name: PaymentCard.frontImageName, data: data))
        }
        if let data = backImage?.jpegData(compressionQuality: 0.75) {
            entry.attachments.append(Attachment(name: PaymentCard.backImageName, data: data))
        }
    }
}

struct CardImageThumb: View {
    let image: UIImage
    /// Front or back of the card.
    let isFront: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.borderless)
                    .offset(x: 6, y: -6)
                    .accessibilityLabel(isFront ? "Remove front image" : "Remove back image")
                }
            Text(isFront ? "Front" : "Back").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Camera document scanner (VisionKit)

struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    /// VisionKit calls these delegate methods on the main thread, so the conformance is checked at run time
    /// rather than treated as nonisolated (`@preconcurrency`).
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<min(scan.pageCount, 2) {
                images.append(scan.imageOfPage(at: index))
            }
            onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

// MARK: - On-device text recognition (Vision)

enum CardTextRecognizer {
    /// Recognises text on a card photo. Vertical cards are retried rotated.
    static func lines(in image: UIImage) async -> [CardTextParser.Line] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeBest(image))
            }
        }
    }

    private static func recognizeBest(_ image: UIImage) -> [CardTextParser.Line] {
        guard let cgImage = image.cgImage else { return [] }
        let base = imageOrientation(image.imageOrientation)
        let first = recognize(cgImage, orientation: base)
        guard base == .up, CardTextParser.parse(front: first).number == nil else { return first }
        for orientation in [CGImagePropertyOrientation.right, .left] {
            let rotated = recognize(cgImage, orientation: orientation)
            if CardTextParser.parse(front: rotated).number != nil { return rotated }
        }
        return first
    }

    private static func recognize(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [CardTextParser.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox // normalised, origin bottom-left
            return CardTextParser.Line(text: text, x: Double(box.minX), y: Double(1 - box.maxY),
                                       width: Double(box.width), height: Double(box.height))
        }
    }

    private static func imageOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
