// SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import UniformTypeIdentifiers
import SwiftUI

/// Copies secrets to the clipboard with local-only scope (no Universal Clipboard)
/// and an expiry date, so they are removed automatically.
@MainActor
enum Clipboard {
    private static var lastChangeCount: Int?

    static func copy(_ text: String, sensitive: Bool = true) {
        let timeout = AppSettings.shared.clipboardTimeout
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if sensitive && timeout > 0 {
            options[.expirationDate] = Date().addingTimeInterval(TimeInterval(timeout))
        }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: options)
        lastChangeCount = UIPasteboard.general.changeCount
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Clears the clipboard if it still holds something this app copied.
    static func clearIfOwned() {
        guard let c = lastChangeCount, UIPasteboard.general.changeCount == c else { return }
        UIPasteboard.general.items = []
        lastChangeCount = nil
    }
}

/// Simple transient message ("Password copied").
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { self?.message = nil }
        }
    }

    /// Copies `text` and confirms it. `label` is the (already translated) name of what was copied.
    func copied(_ text: String, label: String, sensitive: Bool = true) {
        Clipboard.copy(text, sensitive: sensitive)
        let timeout = AppSettings.shared.clipboardTimeout
        if sensitive && timeout > 0 {
            let delay = AppSettings.duration(timeout, style: .short)
            show(String(localized: "\(label) copied · clears in \(delay)"))
        } else {
            show(String(localized: "\(label) copied"))
        }
    }
}

struct ToastOverlay: ViewModifier {
    @ObservedObject var center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = center.message {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3), value: center.message)
    }
}

extension View {
    /// Shows ToastCenter messages ("Password copied") at the bottom of the view.
    @MainActor func toasts() -> some View { modifier(ToastOverlay(center: .shared)) }
}
