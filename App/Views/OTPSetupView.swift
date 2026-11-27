// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AVFoundation
import KeePassCore

struct OTPSetupView: View {
    var initial: OTPConfig?
    var defaultIssuer: String
    var defaultAccount: String
    var onSave: (OTPConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum KindChoice: String, CaseIterable, Identifiable {
        case totp = "TOTP", hotp = "HOTP", steam = "Steam"
        var id: String { rawValue }
    }

    @State private var secret = ""
    @State private var kind = KindChoice.totp
    @State private var digits = 6
    @State private var period = 30
    @State private var counter = 0
    @State private var algorithm = OTPConfig.Algorithm.sha1
    @State private var issuer = ""
    @State private var account = ""
    @State private var showScanner = false
    @State private var message: String?
    @State private var loaded = false

    private var config: OTPConfig? {
        guard let s = Base32.decode(secret), !s.isEmpty else { return nil }
        let k: OTPConfig.Kind
        switch kind {
        case .totp: k = .totp
        case .hotp: k = .hotp(counter: UInt64(max(counter, 0)))
        case .steam: k = .steam
        }
        return OTPConfig(secret: s, kind: k, digits: kind == .steam ? 5 : digits, period: period,
                         algorithm: kind == .steam ? .sha1 : algorithm, issuer: issuer, account: account)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            pasteURI()
                        } label: {
                            Label("Paste otpauth:// link", systemImage: "doc.on.clipboard")
                        }
                    } footer: {
                        if let message { Text(message).foregroundStyle(.red) }
                    }

                    Section("Secret") {
                        TextField("Base32 secret key", text: $secret)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }

                    Section("Settings") {
                        Picker("Type", selection: $kind) {
                            ForEach(KindChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if kind != .steam {
                            Picker("Algorithm", selection: $algorithm) {
                                ForEach(OTPConfig.Algorithm.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Digits", selection: $digits) {
                                ForEach([6, 7, 8, 10], id: \.self) { Text("\($0)").tag($0) }
                            }
                        }
                        if kind == .hotp {
                            Stepper("Counter: \(counter)", value: $counter, in: 0...Int(Int32.max))
                        } else {
                            Stepper("Period: \(period) s", value: $period, in: 5...300, step: 5)
                        }
                    }

                    Section("Label") {
                        TextField("Issuer (e.g. GitHub)", text: $issuer)
                        TextField("Account", text: $account)
                            .textInputAutocapitalization(.never)
                    }

                    if let config {
                        Section("Preview") {
                            OTPCodeView(config: config)
                        }
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("One-time password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let config {
                            onSave(config)
                            dismiss()
                        }
                    }
                    .bold()
                    .disabled(config == nil)
                }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { code in
                        showScanner = false
                        load(uri: code)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan QR code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } }
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let initial { fill(from: initial) } else {
                    issuer = defaultIssuer
                    account = defaultAccount
                }
            }
        }
    }

    private func fill(from c: OTPConfig) {
        secret = Base32.encode(c.secret)
        digits = c.digits
        period = c.period
        algorithm = c.algorithm
        issuer = c.issuer
        account = c.account
        switch c.kind {
        case .totp: kind = .totp
        case .hotp(let n): kind = .hotp; counter = Int(clamping: n)
        case .steam: kind = .steam
        }
    }

    private func load(uri: String) {
        if let c = OTPConfig(uri: uri) {
            fill(from: c)
            if issuer.isEmpty { issuer = defaultIssuer }
            if account.isEmpty { account = defaultAccount }
            message = nil
        } else {
            message = String(localized: "That is not a valid otpauth:// QR code.")
        }
    }

    private func pasteURI() {
        guard let s = UIPasteboard.general.string else {
            message = String(localized: "The clipboard is empty.")
            return
        }
        if s.lowercased().hasPrefix("otpauth://") || s.lowercased().hasPrefix("steam://") {
            load(uri: s)
        } else if Base32.decode(s) != nil {
            secret = s.uppercased().filter { !$0.isWhitespace }
            message = nil
        } else {
            message = String(localized: "The clipboard does not contain an OTP link or secret.")
        }
    }
}

/// Camera QR code scanner.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

/// Lets the capture session be started and stopped on a background queue. AVCaptureSession is safe to use
/// this way (Apple recommends it), but it isn't marked Sendable.
private final class SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didFind = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            // [weak self] belongs on the outer closure: a weak capture only in the inner one would make this
            // closure hold the scanner strongly anyway (Swift 6.4 warns about that).
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configure() } else { self?.showMessage(String(localized: "Camera access was denied.")) }
                }
            }
        default:
            showMessage(String(localized: "Allow camera access in Settings to scan QR codes, or enter the secret manually."))
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            showMessage(String(localized: "No camera is available."))
            return
        }
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        let box = SessionBox(captureSession)
        DispatchQueue.global(qos: .userInitiated).async { box.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            let box = SessionBox(captureSession)
            DispatchQueue.global(qos: .userInitiated).async { box.session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        Task { @MainActor [weak self] in
            self?.found(value)
        }
    }

    private func found(_ value: String) {
        guard !didFind else { return }
        didFind = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(value)
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }
}
