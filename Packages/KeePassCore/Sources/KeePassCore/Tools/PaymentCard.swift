// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// MARK: - Brand

/// Payment card networks, detected from the card number's issuer prefix (IIN).
public enum CardBrand: String, CaseIterable, Identifiable, Codable {
    case visa = "Visa"
    case mastercard = "Mastercard"
    case amex = "American Express"
    case discover = "Discover"
    case diners = "Diners Club"
    case jcb = "JCB"
    case unionPay = "UnionPay"
    case maestro = "Maestro"
    case elo = "Elo"
    case hipercard = "Hipercard"
    case mir = "Mir"
    case rupay = "RuPay"

    public var id: String { rawValue }

    /// Number of digits in the security code (CVV/CVC, or CID on American Express).
    public var securityCodeLength: Int { self == .amex ? 4 : 3 }

    /// Whether a card number of this length is plausible for the brand.
    public func accepts(length: Int) -> Bool {
        switch self {
        case .amex: return length == 15
        case .visa: return [13, 16, 19].contains(length)
        case .mastercard, .elo: return length == 16
        case .diners: return (14...19).contains(length)
        case .maestro: return (12...19).contains(length)
        case .hipercard: return (13...19).contains(length)
        case .discover, .jcb, .unionPay, .mir, .rupay: return (16...19).contains(length)
        }
    }

    /// Digit groups used when displaying a number of the given length.
    public func groupSizes(forLength length: Int) -> [Int] {
        switch self {
        case .amex: return [4, 6, 5]
        case .diners where length == 14: return [4, 6, 4]
        default: return CardBrand.defaultGroups(length)
        }
    }

    static func defaultGroups(_ length: Int) -> [Int] {
        var groups: [Int] = []
        var remaining = max(length, 0)
        while remaining > 0 {
            groups.append(min(4, remaining))
            remaining -= 4
        }
        return groups
    }

    private static let eloPrefixes: Set<Int> = [
        401178, 401179, 431274, 438935, 451416, 457393, 457631, 457632, 504175, 627780, 636297, 636368,
    ]
    private static let eloRanges: [ClosedRange<Int>] = [
        506699...506778, 509000...509999, 650031...650033, 650035...650051, 650405...650439, 650485...650538,
        650541...650598, 650700...650718, 650720...650727, 650901...650978, 651652...651679, 655000...655019,
        655021...655058,
    ]
    private static let hipercardPrefixes: Set<Int> = [606282, 637095, 637568, 637599, 637609, 637612]
    private static let rupayRanges: [ClosedRange<Int>] = [
        508500...508999, 606985...607984, 608001...608500, 652150...653149,
    ]

    /// Detects the brand from a (possibly partial) card number. Returns nil if unknown.
    public static func detect(_ number: String) -> CardBrand? {
        let d = PaymentCard.digits(number)
        guard !d.isEmpty else { return nil }
        func prefix(_ n: Int) -> Int? { d.count >= n ? Int(d.prefix(n)) : nil }

        if let p6 = prefix(6) {
            if eloPrefixes.contains(p6) || eloRanges.contains(where: { $0.contains(p6) }) { return .elo }
            if hipercardPrefixes.contains(p6) { return .hipercard }
            if rupayRanges.contains(where: { $0.contains(p6) }) { return .rupay }
        }
        if let p4 = prefix(4) {
            if p4 == 3841 { return .hipercard }
            if (2200...2204).contains(p4) { return .mir }
            if (3528...3589).contains(p4) { return .jcb }
            if p4 == 3095 { return .diners }
            if p4 == 6011 { return .discover }
            if [6304, 6759, 6761, 6762, 6763].contains(p4) { return .maestro }
            if (2221...2720).contains(p4) { return .mastercard }
        }
        if let p3 = prefix(3) {
            if (300...305).contains(p3) { return .diners }
            if (644...649).contains(p3) { return .discover }
        }
        if let p2 = prefix(2) {
            if p2 == 34 || p2 == 37 { return .amex }
            if [36, 38, 39].contains(p2) { return .diners }
            if p2 == 65 { return .discover }
            if p2 == 62 || p2 == 81 { return .unionPay }
            if (51...55).contains(p2) { return .mastercard }
            if p2 == 50 || (56...58).contains(p2) { return .maestro }
        }
        if d.hasPrefix("4") { return .visa }
        return nil
    }

    /// Finds a brand name printed on the card (used when the number could not be read).
    static func fromText(_ text: String) -> CardBrand? {
        let upper = text.uppercased()
        let words = Set(upper.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if upper.contains("AMERICAN EXPRESS") || words.contains("AMEX") { return .amex }
        if words.contains("MASTERCARD") || upper.contains("MASTER CARD") { return .mastercard }
        if words.contains("MAESTRO") { return .maestro }
        if words.contains("VISA") { return .visa }
        if words.contains("DISCOVER") { return .discover }
        if words.contains("DINERS") { return .diners }
        if words.contains("JCB") { return .jcb }
        if words.contains("UNIONPAY") || upper.contains("UNION PAY") || text.contains("银联") { return .unionPay }
        if words.contains("HIPERCARD") { return .hipercard }
        if words.contains("ELO") { return .elo }
        if words.contains("MIR") || words.contains("МИР") { return .mir }
        if words.contains("RUPAY") { return .rupay }
        return nil
    }
}

// MARK: - Luhn

public enum Luhn {
    /// Validates a card number with the Luhn (mod 10) checksum.
    public static func isValid(_ number: String) -> Bool {
        let digits = PaymentCard.digits(number).compactMap { $0.wholeNumberValue }
        guard digits.count >= 12 else { return false }
        var sum = 0
        for (i, value) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return sum % 10 == 0
    }
}

// MARK: - Expiry

/// A card's "valid thru" month.
public struct CardExpiry: Equatable, Hashable, Comparable {
    public let month: Int
    public let year: Int

    public init?(month: Int, year: Int) {
        let fullYear = year < 100 ? 2000 + year : year
        guard (1...12).contains(month), (1990...2199).contains(fullYear) else { return nil }
        self.month = month
        self.year = fullYear
    }

    /// Parses "MM/YY", "MM/YYYY", "MM-YY", "MM YY", "MMYY" and ISO "YYYY-MM(-DD)".
    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = Regex.groups(#"^(\d{1,2})\s*[/\-.\s]\s*(\d{4}|\d{2})$"#, in: s),
           let month = Int(m[1]), let year = Int(m[2]) {
            self.init(month: month, year: year)
        } else if let m = Regex.groups(#"^(\d{2})(\d{2})$"#, in: s), let month = Int(m[1]), let year = Int(m[2]) {
            self.init(month: month, year: year)
        } else if let m = Regex.groups(#"^(\d{4})[\-/.](\d{1,2})(?:[\-/.]\d{1,2})?(?:[T ].*)?$"#, in: s),
                  let year = Int(m[1]), let month = Int(m[2]) {
            self.init(month: month, year: year)
        } else {
            return nil
        }
    }

    /// The calendar month containing `date` (in the current time zone).
    public init(date: Date) {
        let comps = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        month = comps.month ?? 1
        year = comps.year ?? 2000
    }

    public var shortString: String { String(format: "%02d/%02d", month, year % 100) }

    /// Noon on the last day of the month (local time). Used as the KeePass entry expiry,
    /// the same convention KeePassDX uses for card expiry; noon keeps the month stable across time zones.
    public var keepassDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var c = DateComponents()
        c.year = year
        c.month = month + 1
        c.day = 1
        c.hour = 12
        let firstOfNextMonth = calendar.date(from: c) ?? Date()
        return calendar.date(byAdding: .day, value: -1, to: firstOfNextMonth) ?? firstOfNextMonth
    }

    /// A card is expired once its month has passed.
    public func isExpired(at date: Date = Date()) -> Bool {
        CardExpiry(date: date) > self
    }

    public static func < (a: CardExpiry, b: CardExpiry) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }
}

// MARK: - Card stored in an entry

/// A payment card stored in an entry's fields. Field names follow KeePassDX's
/// "Debit / Credit Card" template (Number, Holder, CVV, PIN; expiry = entry expiry date),
/// so cards created here appear correctly in KeePassDX, and vice versa.
public struct PaymentCard: Equatable {
    public static let numberKey = "Number"
    public static let holderKey = "Holder"
    public static let cvvKey = "CVV"
    public static let pinKey = "PIN"
    public static let brandKey = "Brand"
    public static let frontImageName = "Card front.jpg"
    public static let backImageName = "Card back.jpg"

    static let numberAliases = ["Number", "Card Number", "CardNumber", "Card No", "Card #", "PAN"]
    static let holderAliases = ["Holder", "Card Holder", "Cardholder", "Name on Card", "Name On Card", "Holder Name"]
    static let cvvAliases = ["CVV", "CVC", "CVV2", "CVC2", "CID", "Security Code", "CSC"]
    static let pinAliases = ["PIN"]
    static let brandAliases = ["Brand", "Card Brand", "Card Type"]
    static let expiryAliases = ["Valid Thru", "Expiry", "Expiry Date", "Expiration", "Expiration Date", "Exp", "Valid Until"]

    public var holder = ""
    /// Digits only.
    public var number = ""
    /// Brand name as stored (usually a `CardBrand` raw value); empty means "detect automatically".
    public var brand = ""
    public var expiry: CardExpiry?
    public var cvv = ""
    public var pin = ""

    // Field names this card was read from, so edits are written back to the same fields.
    var numberField = PaymentCard.numberKey
    var holderField = PaymentCard.holderKey
    var cvvField = PaymentCard.cvvKey
    var pinField = PaymentCard.pinKey
    var brandField = PaymentCard.brandKey
    var expiryTextField: String?

    public init() {}

    public static func digits(_ s: String) -> String {
        String(s.filter { $0.isASCII && $0.isNumber })
    }

    // MARK: Display

    public var detectedBrand: CardBrand? { CardBrand.detect(number) }

    public var resolvedBrand: CardBrand? {
        if let exact = CardBrand(rawValue: brand) { return exact }
        if let match = CardBrand.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(brand) == .orderedSame }) {
            return match
        }
        return detectedBrand
    }

    public var brandName: String { brand.isEmpty ? (detectedBrand?.rawValue ?? "") : brand }
    public var last4: String { String(number.suffix(4)) }
    public var maskedNumber: String { number.isEmpty ? "" : "•••• " + last4 }
    public var formattedNumber: String { PaymentCard.format(number, brand: resolvedBrand) }
    public var isNumberValid: Bool { Luhn.isValid(number) }

    public var defaultTitle: String {
        let name = brandName.isEmpty ? localized("Card") : brandName
        return number.isEmpty ? name : "\(name) •••• \(last4)"
    }

    /// Field names occupied by this card (hidden from the generic custom-field list).
    public var fieldKeys: Set<String> {
        var keys: Set<String> = [numberField, holderField, cvvField, pinField, brandField]
        if let expiryTextField { keys.insert(expiryTextField) }
        return keys
    }

    /// Groups digits for display, e.g. "4111 1111 1111 1111" or "3782 822463 10005".
    public static func format(_ input: String, brand: CardBrand? = nil) -> String {
        let d = Array(digits(input).prefix(19))
        guard !d.isEmpty else { return "" }
        let resolved = brand ?? CardBrand.detect(String(d))
        let sizes = resolved?.groupSizes(forLength: d.count) ?? CardBrand.defaultGroups(d.count)
        var parts: [String] = []
        var i = 0
        for size in sizes where i < d.count {
            let end = min(i + size, d.count)
            parts.append(String(d[i..<end]))
            i = end
        }
        if i < d.count { parts.append(String(d[i...])) }
        return parts.joined(separator: " ")
    }

    // MARK: Entry mapping

    private static func field(in entry: KPEntry, keys: [String]) -> EntryField? {
        for key in keys {
            if let f = entry.fields.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { return f }
        }
        return nil
    }

    /// Reads a card from an entry, or returns nil if the entry is not a payment card.
    public static func from(entry: KPEntry) -> PaymentCard? {
        guard let numberField = field(in: entry, keys: numberAliases) else { return nil }
        let number = digits(numberField.value)
        guard (12...19).contains(number.count) else { return nil }
        let holder = field(in: entry, keys: holderAliases)
        let cvv = field(in: entry, keys: cvvAliases)
        let pin = field(in: entry, keys: pinAliases)
        let brand = field(in: entry, keys: brandAliases)
        // A bare "Number" field is only treated as a card number next to other card fields.
        let explicitCardKey = numberField.key.caseInsensitiveCompare(numberKey) != .orderedSame
        let hasCompanions = holder != nil || cvv != nil || brand != nil || (pin != nil && Luhn.isValid(number))
        guard explicitCardKey || hasCompanions else { return nil }

        var card = PaymentCard()
        card.number = number
        card.numberField = numberField.key
        if let holder { card.holder = holder.value; card.holderField = holder.key }
        if let cvv { card.cvv = cvv.value; card.cvvField = cvv.key }
        if let pin { card.pin = pin.value; card.pinField = pin.key }
        if let brand { card.brand = brand.value; card.brandField = brand.key }
        if let text = field(in: entry, keys: expiryAliases), let e = CardExpiry(string: text.value) {
            card.expiry = e
            card.expiryTextField = text.key
        } else if entry.times.expires {
            card.expiry = CardExpiry(date: entry.times.expiry)
        }
        return card
    }

    /// Writes the card into the entry's fields and expiry date.
    public func apply(to entry: KPEntry) {
        entry.setValue(number, for: numberField, protected: true)
        entry.setValue(holder, for: holderField)
        entry.setValue(brand.isEmpty ? (detectedBrand?.rawValue ?? "") : brand, for: brandField)
        entry.setValue(cvv, for: cvvField, protected: true)
        if !pin.isEmpty || entry.field(pinField) != nil {
            entry.setValue(pin, for: pinField, protected: true)
        }
        if let expiry {
            entry.times.expires = true
            entry.times.expiry = expiry.keepassDate
            if let key = expiryTextField { entry.setValue(expiry.shortString, for: key) }
        } else {
            entry.times.expires = false
            if let key = expiryTextField { entry.removeField(key) }
        }
    }
}

// MARK: - Reading a scanned card

/// Extracts card details from text recognised on photos of a card (OCR output).
/// Pure logic, so it can be unit-tested; the app feeds it results from Apple's Vision framework.
public enum CardTextParser {
    /// A recognised line of text with its bounding box, normalised to 0...1, origin top-left.
    public struct Line: Equatable {
        public var text: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(text: String, x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 0.05) {
            self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
        }

        var midY: Double { y + height / 2 }
    }

    public struct Result: Equatable {
        public var number: String?
        public var holder: String?
        public var expiry: CardExpiry?
        public var cvv: String?
        public var brand: CardBrand?

        public init() {}

        public var foundAnything: Bool { number != nil || holder != nil || expiry != nil || cvv != nil }
    }

    struct Row {
        var text: String
        var y: Double
        var x: Double
    }

    public static func parse(front: [Line], back: [Line] = []) -> Result {
        let frontRows = rows(front)
        let backRows = rows(back)
        var result = Result()

        let frontNumber = findNumber(in: frontRows)
        let hit = frontNumber ?? findNumber(in: backRows)
        result.number = hit?.digits
        result.brand = hit.flatMap { CardBrand.detect($0.digits) } ??
            CardBrand.fromText((frontRows + backRows).map(\.text).joined(separator: "\n"))
        result.expiry = findExpiry(in: frontRows + backRows)
        // The name often shares a line with the brand logo, so single lines are candidates too.
        result.holder = findHolder(in: frontRows + singleRows(front), numberRowY: frontNumber?.y)
        if result.holder == nil, !back.isEmpty {
            // Some cards (e.g. vertical designs) print the name on the back.
            result.holder = findHolder(in: backRows + singleRows(back), numberRowY: frontNumber == nil ? hit?.y : nil)
        }
        result.cvv = findCVV(front: frontRows, back: backRows, number: result.number, brand: result.brand)
        return result
    }

    // MARK: Rows

    static func rows(_ lines: [Line]) -> [Row] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.midY < $1.midY }
        var groups: [[Line]] = []
        for line in sorted {
            if let last = groups.last {
                let avgMid = last.map(\.midY).reduce(0, +) / Double(last.count)
                let tolerance = max(last.map(\.height).max() ?? 0, line.height) * 0.6
                if abs(line.midY - avgMid) <= tolerance {
                    groups[groups.count - 1].append(line)
                    continue
                }
            }
            groups.append([line])
        }
        return groups.map { group in
            let ordered = group.sorted { $0.x < $1.x }
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return Row(text: text, y: group.map(\.midY).reduce(0, +) / Double(group.count), x: ordered.first?.x ?? 0)
        }
    }

    static func singleRows(_ lines: [Line]) -> [Row] {
        lines.map { Row(text: $0.text.trimmingCharacters(in: .whitespaces), y: $0.midY, x: $0.x) }
    }

    // MARK: Number

    private static let lookalikes: [Character: Character] = [
        "O": "0", "o": "0", "D": "0", "Q": "0", "I": "1", "l": "1", "|": "1", "i": "1",
        "S": "5", "s": "5", "B": "8", "Z": "2", "z": "2", "G": "6",
    ]

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Fixes common OCR confusions (O→0, I→1, S→5 …) inside tokens that already contain digits.
    static func normalizeDigits(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let t = String(token)
            guard t.contains(where: isDigit),
                  t.allSatisfy({ isDigit($0) || lookalikes[$0] != nil || $0 == "-" }) else { return t }
            return String(t.map { lookalikes[$0] ?? $0 })
        }.joined(separator: " ")
    }

    struct NumberHit {
        let digits: String
        let y: Double
    }

    /// Runs of digit groups separated by spaces or dashes, e.g. ["4111","1111","1111","1111"].
    static func digitRuns(_ text: String) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if !parts.isEmpty && parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) {
                current += parts
            } else {
                if !current.isEmpty { runs.append(current) }
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func numberCandidates(_ groups: [String]) -> [String] {
        var result: [String] = []
        for start in groups.indices {
            var acc = ""
            for end in start..<groups.count {
                acc += groups[end]
                if acc.count > 19 { break }
                if acc.count >= 12 && Luhn.isValid(acc) { result.append(acc) }
            }
        }
        // A single long run (OCR merged neighbouring digits): try common lengths from the start.
        for group in groups where group.count > 12 {
            for length in [16, 15, 19, 18, 17, 14, 13] where group.count > length {
                let prefix = String(group.prefix(length))
                if Luhn.isValid(prefix) { result.append(prefix) }
            }
        }
        return result
    }

    static func findNumber(in rows: [Row]) -> NumberHit? {
        var best: (hit: NumberHit, score: Int)?
        for row in rows {
            for run in digitRuns(normalizeDigits(row.text)) {
                for candidate in numberCandidates(run) {
                    var score = 10
                    if candidate.count == 16 { score += 5 }
                    if let brand = CardBrand.detect(candidate) {
                        score += brand.accepts(length: candidate.count) ? 10 : 2
                    }
                    if best == nil || score > best!.score {
                        best = (NumberHit(digits: candidate, y: row.y), score)
                    }
                }
            }
        }
        return best?.hit
    }

    // MARK: Expiry

    static func findExpiry(in rows: [Row]) -> CardExpiry? {
        var found: [CardExpiry] = []
        for row in rows {
            let text = normalizeDigits(row.text)
            for m in Regex.allGroups(#"(?<!\d)(0[1-9]|1[0-2])\s?[/\-]\s?(\d{4}|\d{2})(?!\d)"#, in: text) {
                if let month = Int(m[1]), let year = Int(m[2]), let e = CardExpiry(month: month, year: year) {
                    found.append(e)
                }
            }
        }
        // With "valid from" and "valid thru" on the card, the later one is the expiry.
        return found.max()
    }

    // MARK: Holder

    static let stopWords: Set<String> = [
        "VISA", "MASTERCARD", "MASTER", "CARD", "CARDS", "DEBIT", "CREDIT", "BANK", "VALID", "THRU", "THROUGH",
        "FROM", "MONTH", "YEAR", "EXPIRES", "EXPIRY", "EXP", "GOOD", "MEMBER", "SINCE", "PLATINUM", "GOLD",
        "CLASSIC", "SIGNATURE", "INFINITE", "WORLD", "ELITE", "BUSINESS", "CORPORATE", "ELECTRON", "PREPAID",
        "AMERICAN", "EXPRESS", "DISCOVER", "MAESTRO", "UNIONPAY", "JCB", "DINERS", "CLUB", "INTERNATIONAL",
        "CONTACTLESS", "CUSTOMER", "ATM", "BLACK", "PREMIUM", "STANDARD", "NATIONAL", "AUTHORIZED",
        "ELO", "HIPERCARD", "RUPAY", "MIR", "PAY", "MOBILE", "ONLINE", "VIRTUAL", "EUROPE", "EURO", "USA",
        // Portuguese / Spanish / French / Italian / German
        "BANCO", "CARTAO", "CARTÃO", "DEBITO", "DÉBITO", "CREDITO", "CRÉDITO", "VALIDO", "VÁLIDO", "VALIDA",
        "VÁLIDA", "ATE", "ATÉ", "DESDE", "MES", "MÊS", "ANO", "TITULAR", "CLIENTE", "TARJETA", "HASTA",
        "CARTE", "BANQUE", "CARTA", "KARTE", "GÜLTIG", "BIS", "INTERNACIONAL", "NACIONAL", "MULTIBANCO",
    ]

    static func findHolder(in rows: [Row], numberRowY: Double?) -> String? {
        var best: (name: String, score: Double)?
        for row in rows {
            let cleaned = row.text
                .split(separator: " ")
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.contains(where: { $0.isNumber }) else { continue }
            let words = cleaned.split(separator: " ").map(String.init)
            guard (1...5).contains(words.count),
                  words.allSatisfy({ w in w.allSatisfy { $0.isLetter || "'.-".contains($0) } }) else { continue }
            let letterCount = cleaned.filter(\.isLetter).count
            guard (4...32).contains(letterCount) else { continue }
            let isStop = words.contains { w in
                stopWords.contains(w.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-'")))
            }
            if isStop { continue }

            var score = 0.0
            score += words.count >= 2 ? 3 : -2
            if cleaned == cleaned.uppercased() { score += 2 }
            if let numberRowY { score += row.y > numberRowY ? 3 : -2 }
            score += row.y
            if row.x < 0.5 { score += 1 }
            if best == nil || score > best!.score { best = (cleaned, score) }
        }
        guard let best, best.score > 2 else { return nil }
        return best.name
    }

    // MARK: Security code

    static func findCVV(front: [Row], back: [Row], number: String?, brand: CardBrand?) -> String? {
        let length = brand?.securityCodeLength ?? 3
        let rows = brand == .amex ? front : back
        guard !rows.isEmpty else { return nil }
        let last4 = number.map { String($0.suffix(4)) }
        let numberGroups = Set(number.map { PaymentCard.format($0, brand: brand).split(separator: " ").map(String.init) } ?? [])
        let keywords = ["CVV", "CVC", "CV2", "CID", "CSC", "SECURITY", "CÓDIGO", "CODIGO"]
        var candidates: [(value: String, score: Int)] = []
        for row in rows {
            let tokens = normalizeDigits(row.text).split(separator: " ").map(String.init)
            let hasKeyword = keywords.contains { row.text.uppercased().contains($0) }
            for (i, token) in tokens.enumerated() where token.count == length && token.allSatisfy(isDigit) {
                if brand == .amex && numberGroups.contains(token) { continue }
                let prev = i > 0 ? tokens[i - 1] : nil
                let next = i + 1 < tokens.count ? tokens[i + 1] : nil
                var score = 1
                if hasKeyword { score += 3 }
                if let prev, prev == last4 {
                    score += 4
                } else if let prev, prev.allSatisfy(isDigit) {
                    score -= 3
                }
                if let next, next.allSatisfy(isDigit) { score -= 3 }
                candidates.append((token, score))
            }
        }
        let plausible = candidates.filter { $0.score > 0 }
        guard let top = plausible.max(by: { $0.score < $1.score }) else { return nil }
        // Ambiguous: two different values equally likely.
        if plausible.contains(where: { $0.score == top.score && $0.value != top.value }) { return nil }
        return top.value
    }
}

// MARK: - Regex helper

enum Regex {
    static func groups(_ pattern: String, in text: String) -> [String]? {
        allGroups(pattern, in: text).first
    }

    static func allGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { i in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
