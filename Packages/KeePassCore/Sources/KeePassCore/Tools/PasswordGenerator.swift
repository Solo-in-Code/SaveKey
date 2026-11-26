// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public struct PasswordOptions: Codable, Equatable {
    public var length = 20
    public var uppercase = true
    public var lowercase = true
    public var digits = true
    public var minus = false
    public var underline = false
    public var space = false
    public var special = true
    public var brackets = false
    public var extendedASCII = false
    public var excludeAmbiguous = false
    public var requireEveryGroup = true
    public var customCharacters = ""
    public var excludedCharacters = ""

    public init() {}
}

public struct PassphraseOptions: Codable, Equatable {
    public enum Capitalization: String, Codable, CaseIterable, Identifiable {
        case lower, title, upper
        public var id: String { rawValue }
    }
    public var wordCount = 5
    public var separator = "-"
    public var capitalization = Capitalization.title
    public var appendDigit = true

    public init() {}
}

public enum PasswordGenerator {
    static let upperSet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lowerSet = Array("abcdefghijklmnopqrstuvwxyz")
    static let digitSet = Array("0123456789")
    static let specialSet = Array("!\"#$%&'*+,./:;=?@\\^`|~")
    static let bracketSet = Array("[]{}()<>")
    static let extendedSet: [Character] = (0xA1...0xFF).compactMap { Unicode.Scalar($0).map(Character.init) }
    static let ambiguous = Set("Il1|O0oB8S5Z2`'\"")

    public static func generate(_ o: PasswordOptions) -> String {
        let excluded = Set(o.excludedCharacters).union(o.excludeAmbiguous ? ambiguous : [])
        var groups: [[Character]] = []
        if o.uppercase { groups.append(upperSet) }
        if o.lowercase { groups.append(lowerSet) }
        if o.digits { groups.append(digitSet) }
        if o.minus { groups.append(["-"]) }
        if o.underline { groups.append(["_"]) }
        if o.space { groups.append([" "]) }
        if o.special { groups.append(specialSet) }
        if o.brackets { groups.append(bracketSet) }
        if o.extendedASCII { groups.append(extendedSet) }
        if !o.customCharacters.isEmpty { groups.append(Array(Set(o.customCharacters))) }
        groups = groups.map { $0.filter { !excluded.contains($0) } }.filter { !$0.isEmpty }
        guard !groups.isEmpty, o.length > 0 else { return "" }

        let pool = Array(Set(groups.joined()))
        var chars: [Character] = []
        if o.requireEveryGroup && o.length >= groups.count {
            for g in groups { chars.append(g[SecureRandom.uniform(g.count)]) }
        }
        while chars.count < o.length { chars.append(pool[SecureRandom.uniform(pool.count)]) }
        // Fisher-Yates shuffle with the secure generator.
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            chars.swapAt(i, SecureRandom.uniform(i + 1))
        }
        return String(chars)
    }

    public static let wordList: [String] = {
        guard let url = Bundle.module.url(forResource: "eff_large_wordlist", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()

    public static func generatePassphrase(_ o: PassphraseOptions) -> String {
        let words = wordList
        guard !words.isEmpty, o.wordCount > 0 else { return "" }
        var parts = (0..<o.wordCount).map { _ -> String in
            let w = words[SecureRandom.uniform(words.count)]
            switch o.capitalization {
            case .lower: return w
            case .upper: return w.uppercased()
            case .title: return w.prefix(1).uppercased() + w.dropFirst()
            }
        }
        if o.appendDigit {
            let i = SecureRandom.uniform(parts.count)
            parts[i] += String(SecureRandom.uniform(10))
        }
        return parts.joined(separator: o.separator)
    }

    /// Estimated entropy in bits for a password generated with these options.
    public static func entropy(_ o: PassphraseOptions) -> Double {
        Double(o.wordCount) * log2(Double(max(wordList.count, 1))) + (o.appendDigit ? log2(10) : 0)
    }
}

public enum PasswordStrength: Int, Comparable, CaseIterable {
    case veryWeak, weak, fair, strong, veryStrong

    public static func < (a: PasswordStrength, b: PasswordStrength) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .veryWeak: return localized("Very weak")
        case .weak: return localized("Weak")
        case .fair: return localized("Fair")
        case .strong: return localized("Strong")
        case .veryStrong: return localized("Very strong")
        }
    }

    public init(bits: Double) {
        switch bits {
        case ..<28: self = .veryWeak
        case ..<45: self = .weak
        case ..<64: self = .fair
        case ..<100: self = .strong
        default: self = .veryStrong
        }
    }

    /// Rough entropy estimate: character-pool size, discounted for repeats and simple sequences.
    public static func estimateBits(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0
        let scalars = password.unicodeScalars
        if scalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII }) { pool += 26 }
        if scalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) { pool += 26 }
        if scalars.contains(where: { CharacterSet.decimalDigits.contains($0) && $0.isASCII }) { pool += 10 }
        if scalars.contains(where: { $0.isASCII && !CharacterSet.alphanumerics.contains($0) }) { pool += 33 }
        if scalars.contains(where: { !$0.isASCII }) { pool += 100 }
        let chars = Array(password)
        var effective = 0.0
        for (i, c) in chars.enumerated() {
            if i > 0 && chars[i - 1] == c { effective += 0.25; continue }
            if i > 1, let a = chars[i - 2].asciiValue, let b = chars[i - 1].asciiValue, let d = c.asciiValue,
               Int(b) - Int(a) == Int(d) - Int(b), abs(Int(d) - Int(b)) == 1 {
                effective += 0.5; continue
            }
            effective += 1
        }
        return effective * log2(Double(max(pool, 1)))
    }

    public static func of(_ password: String) -> PasswordStrength {
        PasswordStrength(bits: estimateBits(password))
    }
}
