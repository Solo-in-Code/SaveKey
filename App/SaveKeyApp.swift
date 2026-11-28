// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import KeePassCore

@main
struct SaveKeyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = DatabaseLibrary.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Let Password AutoFill use the language chosen for SaveKey.
        AppLanguage.shareWithExtension()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(appState)
                .toasts()
                .onOpenURL { url in appState.handleOpen(url: url, library: library) }
        }
        .onChange(of: scenePhase) { phase in
            appState.scenePhaseChanged(phase)
        }
    }
}

extension UTType {
    static let kdbx = UTType(importedAs: "org.keepass.kdbx", conformingTo: .data)
}

/// App-wide state: the unlocked session, auto-lock and the privacy shield.
@MainActor
final class AppState: ObservableObject {
    @Published var session: DatabaseSession?
    @Published var isObscured = false
    @Published var pendingUnlock: DatabaseReference?
    @Published var openError: String?
    /// Whether the database list should offer to unlock the last-used database
    /// (on launch and after an automatic lock, but not after locking manually).
    var shouldAutoOpenLastDatabase = true
    private var backgroundedAt: Date?

    func lock(automatic: Bool = false) {
        shouldAutoOpenLastDatabase = automatic
        session = nil
        if AppSettings.shared.clearClipboardOnLock { Clipboard.clearIfOwned() }
        TemporaryFiles.removeAll()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        let timeout = AppSettings.shared.lockTimeout
        ScreenShield.shared.setInAppSwitcher(phase != .active)
        switch phase {
        case .active:
            isObscured = false
            if let since = backgroundedAt {
                backgroundedAt = nil
                if session != nil && timeout >= 0 && Date().timeIntervalSince(since) >= TimeInterval(timeout) {
                    lock(automatic: true)
                }
            }
        case .inactive:
            isObscured = true
        case .background:
            isObscured = true
            backgroundedAt = Date()
            if timeout == 0 && session != nil { lock(automatic: true) }
        @unknown default:
            break
        }
    }

    /// Handles a .kdbx opened from Files / share sheet ("Open in SaveKey").
    func handleOpen(url: URL, library: DatabaseLibrary) {
        do {
            let ref = try library.add(url: url)
            if session?.reference.id != ref.id {
                if session != nil { lock() }
                pendingUnlock = ref
            }
        } catch {
            openError = error.localizedDescription
        }
    }
}

/// Decrypted attachments are written to a private temporary folder for preview/sharing
/// and removed when the database locks.
enum TemporaryFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "_").isEmpty ? "attachment" : name.replacingOccurrences(of: "/", with: "_")
        let url = folder.appendingPathComponent(safeName)
        try data.write(to: url, options: [.completeFileProtection])
        return url
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            if let session = appState.session {
                DatabaseBrowserView()
                    .environmentObject(session)
                    .id(session.id)
                    .transition(.opacity)
            } else {
                DatabaseListView()
                    .transition(.opacity)
            }
            if appState.isObscured {
                // ScreenShield's own window covers everything, sheets included; this covers the rest of the
                // screen in case that window isn't there yet.
                ShieldView(explainsCapture: false)
            }
        }
        .background(CaptureWatcher().frame(width: 0, height: 0))
        .animation(.easeInOut(duration: 0.2), value: appState.session?.id)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onChange(of: settings.hideDuringScreenCapture) { _ in ScreenShield.shared.update() }
        .onChange(of: settings.blockScreenshots) { _ in ScreenShield.shared.updateScreenshotBlocking() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            // The screenshot is already taken (blank) when iOS tells us; say why, so it isn't a surprise.
            if ScreenShield.shared.blocksScreenshots {
                ToastCenter.shared.show(String(localized: "Screenshots of SaveKey are blank. You can allow them in Settings."),
                                        seconds: 4)
            }
        }
        .alert("Could not open file", isPresented: Binding(get: { appState.openError != nil },
                                                           set: { if !$0 { appState.openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.openError ?? "")
        }
    }
}

// MARK: - Screen protection

/// What covers SaveKey: its logo, and while the screen is being captured, why SaveKey is hidden.
struct ShieldView: View {
    var explainsCapture: Bool

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)
                Text("SaveKey").font(.title2.bold())
                if explainsCapture {
                    Text("Hidden while your screen is shared")
                        .font(.headline)
                        .padding(.top, 12)
                    Text("SaveKey stays hidden while the screen is recorded, mirrored, shared or controlled remotely, and comes back when that stops.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
    }
}

/// Covers SaveKey with its logo in the app switcher and, with Settings › Hide during screen sharing, while iOS
/// records, mirrors, shares or remotely controls the screen (Apple's "Protecting sensitive content when screen
/// sharing and remote control are active"). The cover is a window of its own above all of SaveKey's windows, so it
/// also hides sheets and alerts, and it takes every tap, so nothing underneath can be used.
///
/// It also keeps SaveKey's window out of screenshots, with Settings › Block screenshots.
@MainActor
final class ScreenShield {
    static let shared = ScreenShield()

    private weak var appWindow: UIWindow?
    private var cover: UIWindow?
    private var inAppSwitcher = false
    private var screenIsCaptured = false
    /// Whether screenshots of SaveKey currently come out blank.
    private(set) var blocksScreenshots = false

    /// Called with SaveKey's main window once it exists.
    func attach(to window: UIWindow) {
        appWindow = window
        updateScreenshotBlocking()
        update()
    }

    func setInAppSwitcher(_ value: Bool) {
        inAppSwitcher = value
        update()
    }

    func setScreenCaptured(_ value: Bool) {
        guard value != screenIsCaptured else { return }
        screenIsCaptured = value
        update()
    }

    /// Shows, updates or removes the cover to match the app's state and the settings.
    func update() {
        let hideForCapture = screenIsCaptured && AppSettings.shared.hideDuringScreenCapture
        guard inAppSwitcher || hideForCapture, let scene = appWindow?.windowScene else {
            cover?.isHidden = true
            return
        }
        // Close the keyboard while the screen is captured, so its keys can't show what's being typed.
        if hideForCapture { appWindow?.endEditing(true) }
        let window = cover ?? makeCover(in: scene)
        window.overrideUserInterfaceStyle = Self.interfaceStyle
        (window.rootViewController as? UIHostingController<ShieldView>)?.rootView = ShieldView(explainsCapture: hideForCapture)
        window.isHidden = false
    }

    /// Applies Settings › Block screenshots to SaveKey's window.
    func updateScreenshotBlocking() {
        guard let appWindow else { return }
        let wanted = AppSettings.shared.blockScreenshots
        blocksScreenshots = ScreenshotBlocking.set(wanted, on: appWindow) && wanted
    }

    private func makeCover(in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: ShieldView(explainsCapture: false))
        host.view.accessibilityViewIsModal = true  // VoiceOver reads the cover only, not what's underneath
        window.rootViewController = host
        cover = window
        return window
    }

    /// The cover follows Settings › Appearance, like the rest of SaveKey.
    private static var interfaceStyle: UIUserInterfaceStyle {
        switch AppSettings.shared.appearance.colorScheme {
        case .dark?: return .dark
        case .light?: return .light
        default: return .unspecified
        }
    }
}

/// Keeps a window out of screenshots, screen recordings and the app switcher, and with that out of Siri AI and
/// other assistants that read the screen by capturing it. Only on iOS 27 and later, where it has been checked.
///
/// iOS has no public API for this. A password field keeps its text out of captures by marking the layer it draws
/// in, so SaveKey has a password field put that mark on SaveKey's window instead; Signal uses the same approach on
/// iOS 27. As this relies on UIKit internals, SaveKey first checks that they look as expected, and if they don't,
/// it does nothing rather than risk a crash.
@MainActor
enum ScreenshotBlocking {
    /// Whether screenshots can be blocked on this iPhone.
    static let isAvailable = drawingView(of: UITextField()) != nil

    /// Turns blocking on or off for `window`, and returns whether it could.
    @discardableResult
    static func set(_ block: Bool, on window: UIWindow) -> Bool {
        let field = UITextField()
        guard let canvas = drawingView(of: field) else { return false }
        let canvasLayer = canvas.layer
        let windowLayer = window.layer
        // Lend the window's layer to the field's drawing view, turn secure entry off and on (or on and off) so the
        // field marks (or unmarks) that layer, then give the drawing view its own layer back.
        canvas.setValue(windowLayer, forKey: "layer")
        field.isSecureTextEntry = !block
        field.isSecureTextEntry = block
        canvas.setValue(canvasLayer, forKey: "layer")
        // The window has to stay its layer's delegate, or it would stop drawing.
        if (windowLayer.delegate as AnyObject?) !== window { windowLayer.delegate = window }
        return true
    }

    /// The view a UITextField draws its text in, if this iOS builds the field the way SaveKey expects and the view's
    /// layer can be swapped.
    private static func drawingView(of field: UITextField) -> UIView? {
        guard #available(iOS 27, *),
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              let canvas = field.subviews.first(where: { String(describing: type(of: $0)).contains("TextLayoutCanvasView") })
        else { return nil }
        let viewClass: AnyClass = type(of: canvas)
        let layerIsSettable = canvas.responds(to: NSSelectorFromString("setLayer:"))
            || (type(of: canvas).accessInstanceVariablesDirectly && class_getInstanceVariable(viewClass, "_layer") != nil)
        return layerIsSettable ? canvas : nil
    }
}

/// An invisible view in SaveKey's window. It hands the window to ScreenShield and reports when iOS starts or stops
/// recording, mirroring, sharing or remotely controlling the screen.
private struct CaptureWatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> CaptureWatcherView { CaptureWatcherView() }
    func updateUIView(_ uiView: CaptureWatcherView, context: Context) {}
}

final class CaptureWatcherView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        if #available(iOS 17.0, *) {
            _ = registerForTraitChanges([UITraitSceneCaptureState.self], target: self, action: #selector(captureMayHaveChanged))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(captureMayHaveChanged),
                                               name: UIScreen.capturedDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        // Once SwiftUI has finished laying out, not in the middle of it.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            ScreenShield.shared.attach(to: window)
            self.captureMayHaveChanged()
        }
    }

    @objc private func captureMayHaveChanged() {
        ScreenShield.shared.setScreenCaptured(isCaptured)
    }

    private var isCaptured: Bool {
        guard let window else { return false }
        if #available(iOS 17.0, *) {
            return traitCollection.sceneCaptureState == .active
        }
        return window.windowScene?.screen.isCaptured ?? false
    }
}

/// Lets SaveKey turn away third-party keyboards (Settings › Allow other keyboards). Password fields always use
/// Apple's keyboard; this extends that to every field, so a keyboard can't read notes, names or a shown password.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        // iOS asks once and keeps the answer until SaveKey is closed.
        extensionPointIdentifier != .keyboard || AppSettings.shared.allowOtherKeyboards
    }
}
