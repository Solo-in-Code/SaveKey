// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Combine
import KeePassCore

enum EntrySort: String, CaseIterable, Identifiable {
    case title, modified, created, userName
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return String(localized: "Title")
        case .modified: return String(localized: "Last modified")
        case .created: return String(localized: "Created")
        case .userName: return String(localized: "Username")
        }
    }

    func sorted(_ entries: [KPEntry]) -> [KPEntry] {
        switch self {
        case .title:
            return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .modified:
            return entries.sorted { $0.times.lastModification > $1.times.lastModification }
        case .created:
            return entries.sorted { $0.times.creation > $1.times.creation }
        case .userName:
            return entries.sorted { $0.userName.localizedStandardCompare($1.userName) == .orderedAscending }
        }
    }
}

/// User preferences, stored in the shared app-group defaults so AutoFill sees them too.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = AppConfig.sharedDefaults

    /// Seconds before copied secrets are removed from the clipboard (0 = never).
    @Published var clipboardTimeout: Int { didSet { defaults.set(clipboardTimeout, forKey: "clipboardTimeout") } }
    /// Seconds in the background before the database locks (0 = immediately, -1 = never).
    @Published var lockTimeout: Int { didSet { defaults.set(lockTimeout, forKey: "lockTimeout") } }
    @Published var autoPromptBiometrics: Bool { didSet { defaults.set(autoPromptBiometrics, forKey: "autoPromptBiometrics") } }
    @Published var rememberKeyFiles: Bool { didSet { defaults.set(rememberKeyFiles, forKey: "rememberKeyFiles") } }
    @Published var showPasswordsByDefault: Bool { didSet { defaults.set(showPasswordsByDefault, forKey: "showPasswords") } }
    @Published var quickTypeSuggestions: Bool { didSet { defaults.set(quickTypeSuggestions, forKey: "quickTypeSuggestions") } }
    @Published var autoFillCopiesOTP: Bool { didSet { defaults.set(autoFillCopiesOTP, forKey: "autoFillCopiesOTP") } }
    @Published var clearClipboardOnLock: Bool { didSet { defaults.set(clearClipboardOnLock, forKey: "clearClipboardOnLock") } }
    /// Cover SaveKey while the screen is recorded, mirrored, shared or controlled remotely.
    @Published var hideDuringScreenCapture: Bool { didSet { defaults.set(hideDuringScreenCapture, forKey: "hideDuringScreenCapture") } }
    /// Keep SaveKey out of screenshots, and so out of assistants that read the screen (iOS 27 and later).
    @Published var blockScreenshots: Bool { didSet { defaults.set(blockScreenshots, forKey: "blockScreenshots") } }
    /// Let third-party keyboards type in SaveKey. When off, SaveKey always uses Apple's keyboard.
    @Published var allowOtherKeyboards: Bool { didSet { defaults.set(allowOtherKeyboards, forKey: "allowOtherKeyboards") } }
    @Published var entrySort: EntrySort { didSet { defaults.set(entrySort.rawValue, forKey: "entrySort") } }
    @Published var showRecycleBin: Bool { didSet { defaults.set(showRecycleBin, forKey: "showRecycleBin") } }
    /// Show each website's logo for entries with a web address (downloads logos from those sites).
    @Published var showWebsiteIcons: Bool { didSet { defaults.set(showWebsiteIcons, forKey: "showWebsiteIcons") } }
    /// Automatic (follows the iPhone), Light or Dark. Dark uses the SaveKey slate colours.
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var passwordOptions: PasswordOptions { didSet { store(passwordOptions, "passwordOptions") } }
    @Published var passphraseOptions: PassphraseOptions { didSet { store(passphraseOptions, "passphraseOptions") } }
    @Published var generatorUsesPassphrase: Bool { didSet { defaults.set(generatorUsesPassphrase, forKey: "generatorUsesPassphrase") } }

    init() {
        let defaults = AppConfig.sharedDefaults
        defaults.register(defaults: [
            "clipboardTimeout": 60,
            "lockTimeout": 60,
            "autoPromptBiometrics": true,
            "rememberKeyFiles": true,
            "showPasswords": false,
            "quickTypeSuggestions": false,
            "autoFillCopiesOTP": true,
            "clearClipboardOnLock": true,
            "hideDuringScreenCapture": true,
            "blockScreenshots": true,
            "allowOtherKeyboards": false,
            "showRecycleBin": true,
            "showWebsiteIcons": false,
        ])
        clipboardTimeout = defaults.integer(forKey: "clipboardTimeout")
        lockTimeout = defaults.integer(forKey: "lockTimeout")
        autoPromptBiometrics = defaults.bool(forKey: "autoPromptBiometrics")
        rememberKeyFiles = defaults.bool(forKey: "rememberKeyFiles")
        showPasswordsByDefault = defaults.bool(forKey: "showPasswords")
        quickTypeSuggestions = defaults.bool(forKey: "quickTypeSuggestions")
        autoFillCopiesOTP = defaults.bool(forKey: "autoFillCopiesOTP")
        clearClipboardOnLock = defaults.bool(forKey: "clearClipboardOnLock")
        hideDuringScreenCapture = defaults.bool(forKey: "hideDuringScreenCapture")
        blockScreenshots = defaults.bool(forKey: "blockScreenshots")
        allowOtherKeyboards = defaults.bool(forKey: "allowOtherKeyboards")
        showRecycleBin = defaults.bool(forKey: "showRecycleBin")
        showWebsiteIcons = defaults.bool(forKey: "showWebsiteIcons")
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        entrySort = EntrySort(rawValue: defaults.string(forKey: "entrySort") ?? "") ?? .title
        generatorUsesPassphrase = defaults.bool(forKey: "generatorUsesPassphrase")
        passwordOptions = AppSettings.load("passwordOptions", from: defaults) ?? PasswordOptions()
        passphraseOptions = AppSettings.load("passphraseOptions", from: defaults) ?? PassphraseOptions()
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    struct TimeoutOption: Hashable, Identifiable {
        let seconds: Int
        let label: String
        var id: Int { seconds }
    }

    static let clipboardTimeoutOptions: [TimeoutOption] =
        [10, 30, 60, 120, 300].map { TimeoutOption(seconds: $0, label: AppSettings.duration($0)) } +
        [TimeoutOption(seconds: 0, label: String(localized: "Never"))]
    static let lockTimeoutOptions: [TimeoutOption] =
        [TimeoutOption(seconds: 0, label: String(localized: "Immediately"))] +
        [30, 60, 300, 900, 3600].map { TimeoutOption(seconds: $0, label: AppSettings.duration($0)) } +
        [TimeoutOption(seconds: -1, label: String(localized: "Never"))]

    /// A length of time worded by iOS in the app's language: "30 seconds" (full) or "30 sec" (short).
    nonisolated static func duration(_ seconds: Int, style: DateComponentsFormatter.UnitsStyle = .full) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }
}
