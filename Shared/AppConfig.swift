// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import KeePassCore

/// Identifiers shared between the app and the AutoFill extension.
/// They are injected into Info.plist from build settings (see project.yml).
enum AppConfig {
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "KCAppGroupIdentifier") as? String ?? "group.com.example.savekey"
    }

    /// Full keychain access group including the team prefix, e.g. "ABCDE12345.com.example.savekey.shared".
    static var keychainAccessGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "KCKeychainAccessGroup") as? String,
              !g.isEmpty, !g.hasPrefix("$(") else { return nil }
        return g
    }

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// Shown in Settings › License. SaveKey is licensed under the GNU AGPL, version 3 or later.
    static let copyrightNotice = "© 2026 the SaveKey contributors"
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!
}

extension KDBXError {
    var isWrongCredentials: Bool { self == .invalidCredentials }
}
