// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit
import KeePassCore

/// SaveKey colours. Dark mode uses the logo's background colour (#283438).
enum Theme {
    static let slate = UIColor(red: 0x28 / 255, green: 0x34 / 255, blue: 0x38 / 255, alpha: 1)      // #283438
    static let slateRow = UIColor(red: 0x33 / 255, green: 0x42 / 255, blue: 0x47 / 255, alpha: 1)   // #334247
    static let orangeUI = UIColor(red: 0xF1 / 255, green: 0x5A / 255, blue: 0x30 / 255, alpha: 1)  // #f15a30
    static let orange = Color(uiColor: orangeUI)

    /// Screen background: the usual grouped background in light mode, slate in dark mode.
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? slate : .systemGroupedBackground
    })

    /// Background of list rows and form fields: white in light mode, a lighter slate in dark mode.
    static let rowBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? slateRow : .secondarySystemGroupedBackground
    })

    /// Built-in icons (folders, entries and the icon collection) use the logo colours: an orange symbol
    /// on a slate tile in light mode, and the opposite (slate symbol on an orange tile) in dark mode.
    static let iconSymbol = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? slate : orangeUI
    })
    static let iconTile = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? orangeUI : slate
    })
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    /// nil follows the iPhone's setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension View {
    /// SaveKey background for a List or Form (slate in dark mode).
    func themedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }

    /// SaveKey row colour; apply to the sections or rows of a List or Form.
    func themedRows() -> some View {
        listRowBackground(Theme.rowBackground)
    }
}

extension KPEntry {
    /// Changes whenever something shown for the entry changes. Entries are reference types, so rows
    /// store this value to make SwiftUI refresh them (and their website icon) after an edit.
    var displayRevision: Int {
        var hasher = Hasher()
        hasher.combine(iconID)
        hasher.combine(customIconUUID)
        hasher.combine(times.lastModification)
        hasher.combine(times.expires)
        hasher.combine(times.expiry)
        hasher.combine(attachments.count)
        hasher.combine(parent?.uuid)
        for field in fields {
            hasher.combine(field.key)
            hasher.combine(field.value)
        }
        return hasher.finalize()
    }
}
