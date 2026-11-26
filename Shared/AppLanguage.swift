// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// SaveKey's languages. SaveKey follows the iPhone's language unless a language is chosen for SaveKey
/// only. The choice is stored where iOS keeps its own per-app language setting (Settings › Apps ›
/// SaveKey › Language), so the two always agree. A new choice applies the next time SaveKey starts.
enum AppLanguage {
    /// Translations included in the app (the .lproj folder names), in the order they are listed.
    static let supported = ["en", "de", "es", "fr", "it", "pt-BR", "pt-PT"]

    private static let appleLanguagesKey = "AppleLanguages"
    /// Copy of the choice in the shared app-group defaults, so the AutoFill extension can follow it.
    private static let sharedKey = "appLanguage"

    /// The language chosen for SaveKey only, or nil when SaveKey follows the iPhone.
    static var chosen: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[appleLanguagesKey] as? [String],
              let first = languages.first else { return nil }
        return match(first)
    }

    /// Chooses a language for SaveKey only; nil follows the iPhone again. Applies after a restart.
    static func choose(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }
        shareWithExtension()
    }

    /// Maps an iOS language ID such as "pt-PT", "de-CH" or "es-419" to one of `supported`.
    static func match(_ id: String) -> String? {
        if supported.contains(id) { return id }
        let parts = id.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let language = parts.first ?? id
        if language == "pt" {
            // Brazilian unless a region other than Brazil is given (Portugal, Angola, Mozambique…).
            let region = parts.dropFirst().first { $0.count == 2 }?.uppercased()
            return region == nil || region == "BR" ? "pt-BR" : "pt-PT"
        }
        return supported.contains(language) ? language : nil
    }

    /// The language's name in that language, e.g. "Deutsch" or "Português (Brasil)".
    static func displayName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Called by the app at launch: lets the AutoFill extension use the same language.
    static func shareWithExtension() {
        let shared = AppConfig.sharedDefaults
        if let chosen {
            shared.set(chosen, forKey: sharedKey)
        } else {
            shared.removeObject(forKey: sharedKey)
        }
    }

    /// Called by the AutoFill extension: adopts the app's choice (used from the extension's next start).
    static func adoptAppChoice() {
        let wanted = AppConfig.sharedDefaults.string(forKey: sharedKey)
        guard chosen != wanted else { return }
        if let wanted {
            UserDefaults.standard.set([wanted], forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }
    }
}
