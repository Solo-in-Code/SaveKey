// SPDX-License-Identifier: AGPL-3.0-or-later
import AuthenticationServices
import SwiftUI
import KeePassCore

/// Password AutoFill entry point. The database is opened read-only here.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var model: AutoFillModel?
    private var host: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Follow the language chosen in SaveKey (takes effect from the extension's next start).
        AppLanguage.adoptAppChoice()
    }

    private func show(_ mode: AutoFillModel.Mode) {
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()

        let model = AutoFillModel(mode: mode, controller: self)
        self.model = model
        let root = AutoFillRootView(model: model)
            .environmentObject(DatabaseLibrary.shared)
            .environmentObject(AppSettings.shared)
            .toasts()
        let hc = UIHostingController(rootView: AnyView(root))
        addChild(hc)
        hc.view.frame = view.bounds
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hc.view)
        hc.didMove(toParent: self)
        host = hc
    }

    // MARK: Requests

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        show(.list(serviceIdentifiers))
    }

    /// QuickType suggestion tapped: the database must be unlocked first.
    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        extensionContext.cancelRequest(withError: Self.error(.userInteractionRequired))
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        show(.identity(credentialIdentity))
    }

    @available(iOS 17.0, *)
    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        extensionContext.cancelRequest(withError: Self.error(.userInteractionRequired))
    }

    @available(iOS 17.0, *)
    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        if let identity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            show(.identity(identity))
        } else {
            cancel()
        }
    }

    override func prepareInterfaceForExtensionConfiguration() {
        show(.configuration)
    }

    // MARK: Completion

    func complete(with entry: KPEntry) {
        if AppSettings.shared.autoFillCopiesOTP, let otp = OTPConfig.from(entry: entry), otp.isTimeBased {
            Clipboard.copy(otp.code())
        }
        let credential = ASPasswordCredential(user: entry.userName, password: entry.password)
        extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
    }

    func cancel() {
        extensionContext.cancelRequest(withError: Self.error(.userCanceled))
    }

    func finishConfiguration() {
        extensionContext.completeExtensionConfigurationRequest()
    }

    private static func error(_ code: ASExtensionError.Code) -> NSError {
        NSError(domain: ASExtensionErrorDomain, code: code.rawValue)
    }
}

@MainActor
final class AutoFillModel: ObservableObject {
    enum Mode {
        case list([ASCredentialServiceIdentifier])
        case identity(ASPasswordCredentialIdentity)
        case configuration
    }

    let mode: Mode
    weak var controller: CredentialProviderViewController?
    @Published var session: DatabaseSession?
    @Published var selectedReference: DatabaseReference?
    @Published var message: String?

    init(mode: Mode, controller: CredentialProviderViewController) {
        self.mode = mode
        self.controller = controller
        let library = DatabaseLibrary.shared
        library.reload()
        if case .identity(let identity) = mode,
           let record = CredentialIdentities.parse(identity.recordIdentifier),
           let ref = library.reference(id: record.database) {
            selectedReference = ref
        } else if let last = library.lastUsedID, let ref = library.reference(id: last) {
            selectedReference = ref
        } else {
            selectedReference = library.references.first
        }
    }

    var identifierStrings: [String] {
        switch mode {
        case .list(let ids): return ids.map(\.identifier)
        case .identity(let identity): return [identity.serviceIdentifier.identifier]
        case .configuration: return []
        }
    }

    var domainLabel: String {
        identifierStrings.compactMap(URLMatcher.host(from:)).first ?? String(localized: "this site")
    }

    func unlocked(_ session: DatabaseSession) {
        if case .identity(let identity) = mode,
           let record = CredentialIdentities.parse(identity.recordIdentifier),
           let entry = session.database.entry(uuid: record.entry) {
            controller?.complete(with: entry)
            return
        }
        self.session = session
    }

    func select(_ entry: KPEntry) { controller?.complete(with: entry) }
    func cancel() { controller?.cancel() }
    func finishConfiguration() { controller?.finishConfiguration() }

    func switchDatabase(_ ref: DatabaseReference) {
        session = nil
        selectedReference = ref
    }
}
