// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import KeePassCore

@main
struct SaveKeyApp: App {
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
                PrivacyShield()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.session?.id)
        .preferredColorScheme(settings.appearance.colorScheme)
        .alert("Could not open file", isPresented: Binding(get: { appState.openError != nil },
                                                           set: { if !$0 { appState.openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.openError ?? "")
        }
    }
}

/// Hides the contents in the app switcher.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)
                Text("SaveKey").font(.title2.bold())
            }
        }
        .ignoresSafeArea()
    }
}
