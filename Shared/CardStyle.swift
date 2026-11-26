// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import KeePassCore

/// Colours used to draw payment cards, per brand.
enum CardStyle {
    static func colors(for brand: CardBrand?) -> [Color] {
        switch brand {
        case .visa?: return [Color(red: 0.07, green: 0.16, blue: 0.47), Color(red: 0.16, green: 0.38, blue: 0.80)]
        case .mastercard?: return [Color(red: 0.13, green: 0.13, blue: 0.16), Color(red: 0.85, green: 0.33, blue: 0.13)]
        case .amex?: return [Color(red: 0.04, green: 0.40, blue: 0.53), Color(red: 0.31, green: 0.69, blue: 0.80)]
        case .discover?: return [Color(red: 0.90, green: 0.42, blue: 0.08), Color(red: 0.98, green: 0.68, blue: 0.25)]
        case .diners?: return [Color(red: 0.20, green: 0.27, blue: 0.36), Color(red: 0.45, green: 0.53, blue: 0.62)]
        case .jcb?: return [Color(red: 0.00, green: 0.38, blue: 0.24), Color(red: 0.18, green: 0.62, blue: 0.40)]
        case .unionPay?: return [Color(red: 0.72, green: 0.09, blue: 0.14), Color(red: 0.10, green: 0.30, blue: 0.60)]
        case .maestro?: return [Color(red: 0.05, green: 0.24, blue: 0.55), Color(red: 0.80, green: 0.15, blue: 0.20)]
        case .elo?: return [Color(red: 0.07, green: 0.07, blue: 0.09), Color(red: 0.32, green: 0.32, blue: 0.36)]
        case .hipercard?: return [Color(red: 0.62, green: 0.04, blue: 0.08), Color(red: 0.88, green: 0.20, blue: 0.20)]
        case .mir?: return [Color(red: 0.00, green: 0.44, blue: 0.30), Color(red: 0.25, green: 0.70, blue: 0.45)]
        case .rupay?: return [Color(red: 0.10, green: 0.29, blue: 0.55), Color(red: 0.94, green: 0.50, blue: 0.10)]
        case nil: return [Color(red: 0.20, green: 0.24, blue: 0.30), Color(red: 0.42, green: 0.47, blue: 0.54)]
        }
    }

    static func gradient(for brand: CardBrand?) -> LinearGradient {
        LinearGradient(colors: colors(for: brand), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Short label printed on the small card icon.
    static func shortLabel(for brand: CardBrand?) -> String {
        switch brand {
        case .visa?: return "VISA"
        case .mastercard?: return "MC"
        case .amex?: return "AMEX"
        case .discover?: return "DISC"
        case .diners?: return "DC"
        case .jcb?: return "JCB"
        case .unionPay?: return "UP"
        case .maestro?: return "MAE"
        case .elo?: return "ELO"
        case .hipercard?: return "HIPER"
        case .mir?: return "MIR"
        case .rupay?: return "RUPAY"
        case nil: return ""
        }
    }
}

/// Small card-shaped icon used in entry lists.
struct CardBadge: View {
    var brand: CardBrand?
    var size: CGFloat = 34
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
            .fill(CardStyle.gradient(for: brand))
            .frame(width: size, height: size * 0.66)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.82, blue: 0.48))
                    .frame(width: size * 0.22, height: size * 0.16)
                    .padding(.leading, size * 0.12)
                    .padding(.top, size * 0.14)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(CardStyle.shortLabel(for: brand))
                    .font(.system(size: size * 0.18, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.trailing, size * 0.08)
                    .padding(.bottom, size * 0.06)
            }
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}
