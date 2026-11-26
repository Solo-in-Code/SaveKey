// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One-time password configuration (TOTP, HOTP, Steam), read from and written to
/// entries in the formats used by KeePassXC, KeePass 2.47+ and KeePassDX.
public struct OTPConfig: Equatable {
    public enum Algorithm: String, CaseIterable, Identifiable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
        public var id: String { rawValue }
        var keepassName: String {
            switch self {
            case .sha1: return "HMAC-SHA-1"
            case .sha256: return "HMAC-SHA-256"
            case .sha512: return "HMAC-SHA-512"
            }
        }
    }

    public enum Kind: Equatable {
        case totp
        case hotp(counter: UInt64)
        case steam
    }

    public var kind: Kind = .totp
    public var secret: Data
    public var digits = 6
    public var period = 30
    public var algorithm = Algorithm.sha1
    public var issuer = ""
    public var account = ""

    public init(secret: Data, kind: Kind = .totp, digits: Int = 6, period: Int = 30,
                algorithm: Algorithm = .sha1, issuer: String = "", account: String = "") {
        self.secret = secret; self.kind = kind; self.digits = digits; self.period = period
        self.algorithm = algorithm; self.issuer = issuer; self.account = account
    }

    public static let otpFieldKey = "otp"
    static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

    // MARK: Code generation

    public func code(at date: Date = Date()) -> String {
        let counter: UInt64
        switch kind {
        case .hotp(let c): counter = c
        case .totp, .steam: counter = UInt64(max(0, date.timeIntervalSince1970) / Double(max(period, 1)))
        }
        var msg = Data(count: 8)
        for i in 0..<8 { msg[i] = UInt8((counter >> (UInt64(7 - i) * 8)) & 0xff) }
        let mac: Data
        switch algorithm {
        case .sha1: mac = Hash.hmacSHA1(key: secret, data: msg)
        case .sha256: mac = Hash.hmacSHA256(key: secret, data: msg)
        case .sha512: mac = Hash.hmacSHA512(key: secret, data: msg)
        }
        let bytes = [UInt8](mac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        var value = (UInt32(bytes[offset] & 0x7f) << 24) | (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        if kind == .steam {
            var s = ""
            for _ in 0..<5 {
                s.append(OTPConfig.steamAlphabet[Int(value % UInt32(OTPConfig.steamAlphabet.count))])
                value /= UInt32(OTPConfig.steamAlphabet.count)
            }
            return s
        }
        let d = min(max(digits, 1), 10)
        var modulus: UInt64 = 1
        for _ in 0..<d { modulus *= 10 }
        let code = String(UInt64(value) % modulus)
        return String(repeating: "0", count: max(0, d - code.count)) + code
    }

    /// Seconds until the current code changes (TOTP/Steam only).
    public func remaining(at date: Date = Date()) -> Int {
        let p = max(period, 1)
        return p - Int(date.timeIntervalSince1970) % p
    }

    public var isTimeBased: Bool {
        if case .hotp = kind { return false }
        return true
    }

    // MARK: otpauth:// URIs

    public init?(uri: String) {
        guard let comps = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased() else { return nil }
        if scheme == "steam" {
            guard let host = comps.host, let s = Base32.decode(host) else { return nil }
            self.init(secret: s, kind: .steam, digits: 5)
            return
        }
        guard scheme == "otpauth", let type = comps.host?.lowercased() else { return nil }
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] { params[item.name.lowercased()] = item.value ?? "" }
        guard let secretString = params["secret"], let s = Base32.decode(secretString), !s.isEmpty else { return nil }
        self.init(secret: s)
        if let d = params["digits"], let v = Int(d) { digits = v }
        if let p = params["period"], let v = Int(p), v > 0 { period = v }
        if let a = params["algorithm"]?.uppercased() {
            algorithm = Algorithm(rawValue: a.replacingOccurrences(of: "-", with: "")) ?? .sha1
        }
        var label = comps.path
        if label.hasPrefix("/") { label.removeFirst() }
        label = label.removingPercentEncoding ?? label
        if let colon = label.firstIndex(of: ":") {
            issuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            account = label
        }
        if let i = params["issuer"], !i.isEmpty { issuer = i }
        switch type {
        case "totp":
            if params["encoder"]?.lowercased() == "steam" { kind = .steam; digits = 5 }
        case "hotp":
            kind = .hotp(counter: UInt64(params["counter"] ?? "0") ?? 0)
        default:
            return nil
        }
    }

    public var uri: String {
        var comps = URLComponents()
        comps.scheme = "otpauth"
        switch kind {
        case .totp, .steam: comps.host = "totp"
        case .hotp: comps.host = "hotp"
        }
        let label = issuer.isEmpty ? account : "\(issuer):\(account)"
        comps.path = "/" + label
        var items = [URLQueryItem(name: "secret", value: Base32.encode(secret))]
        if !issuer.isEmpty { items.append(URLQueryItem(name: "issuer", value: issuer)) }
        switch kind {
        case .totp:
            items.append(URLQueryItem(name: "period", value: String(period)))
            items.append(URLQueryItem(name: "digits", value: String(digits)))
            items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue))
        case .steam:
            items.append(URLQueryItem(name: "period", value: String(period)))
            items.append(URLQueryItem(name: "digits", value: "5"))
            items.append(URLQueryItem(name: "encoder", value: "steam"))
        case .hotp(let counter):
            items.append(URLQueryItem(name: "counter", value: String(counter)))
            items.append(URLQueryItem(name: "digits", value: String(digits)))
            items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue))
        }
        comps.queryItems = items
        return comps.string ?? ""
    }

    // MARK: Entry integration

    private static let otpFieldPrefixes = ["TimeOtp-", "HmacOtp-", "TOTP Seed", "TOTP Settings"]

    public static func from(entry: KPEntry) -> OTPConfig? {
        if let field = entry.field(otpFieldKey)?.value, !field.isEmpty {
            if let c = OTPConfig(uri: field) { return c }
            if let c = parseKeeOtp(field) { return c }
        }
        // KeePass 2.47+ native TOTP fields
        if let s = decodeSecret(entry, prefix: "TimeOtp-Secret") {
            var c = OTPConfig(secret: s)
            if let l = Int(entry.value("TimeOtp-Length")) { c.digits = l }
            if let p = Int(entry.value("TimeOtp-Period")), p > 0 { c.period = p }
            switch entry.value("TimeOtp-Algorithm").uppercased() {
            case "HMAC-SHA-256": c.algorithm = .sha256
            case "HMAC-SHA-512": c.algorithm = .sha512
            default: c.algorithm = .sha1
            }
            return c
        }
        // KeePass 2.47+ native HOTP fields
        if let s = decodeSecret(entry, prefix: "HmacOtp-Secret") {
            return OTPConfig(secret: s, kind: .hotp(counter: UInt64(entry.value("HmacOtp-Counter")) ?? 0))
        }
        // Legacy KeePassXC fields
        let seed = entry.value("TOTP Seed")
        if !seed.isEmpty, let s = Base32.decode(seed) {
            var c = OTPConfig(secret: s)
            let settings = entry.value("TOTP Settings").split(separator: ";").map(String.init)
            if settings.count >= 1, let p = Int(settings[0]), p > 0 { c.period = p }
            if settings.count >= 2 {
                if settings[1] == "S" { c.kind = .steam; c.digits = 5 } else if let d = Int(settings[1]) { c.digits = d }
            }
            return c
        }
        return nil
    }

    /// KeeOtp plugin style: `key=BASE32&step=30&size=6&otpHashMode=Sha256`
    private static func parseKeeOtp(_ s: String) -> OTPConfig? {
        var params: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].lowercased()] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let key = params["key"], let secret = Base32.decode(key) else { return nil }
        var c = OTPConfig(secret: secret)
        if let step = Int(params["step"] ?? ""), step > 0 { c.period = step }
        if let size = Int(params["size"] ?? "") { c.digits = size }
        switch params["otphashmode"]?.lowercased() {
        case "sha256": c.algorithm = .sha256
        case "sha512": c.algorithm = .sha512
        default: break
        }
        if params["type"]?.lowercased() == "hotp" { c.kind = .hotp(counter: UInt64(params["counter"] ?? "0") ?? 0) }
        return c
    }

    private static func decodeSecret(_ entry: KPEntry, prefix: String) -> Data? {
        if let v = entry.field(prefix)?.value, !v.isEmpty { return Data(v.utf8) }
        if let v = entry.field(prefix + "-Hex")?.value, let d = Data(hex: v) { return d }
        if let v = entry.field(prefix + "-Base32")?.value, let d = Base32.decode(v) { return d }
        if let v = entry.field(prefix + "-Base64")?.value, let d = Data(base64Encoded: v) { return d }
        return nil
    }

    /// Stores this configuration in the entry (as an `otp` field, the most widely supported format),
    /// removing other OTP representations.
    public func apply(to entry: KPEntry) {
        OTPConfig.remove(from: entry)
        entry.setValue(uri, for: OTPConfig.otpFieldKey, protected: true)
    }

    public static func remove(from entry: KPEntry) {
        entry.fields.removeAll { f in
            f.key == otpFieldKey || otpFieldPrefixes.contains { f.key.hasPrefix($0) }
        }
    }

    /// Whether a field is part of an OTP configuration (hidden from the custom-field list).
    public static func isOTPField(_ key: String) -> Bool {
        key == otpFieldKey || otpFieldPrefixes.contains { key.hasPrefix($0) }
    }

    /// For HOTP: returns a copy with the counter advanced by one.
    public func advanced() -> OTPConfig {
        var c = self
        if case .hotp(let n) = kind { c.kind = .hotp(counter: n + 1) }
        return c
    }
}

public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ s: String) -> Data? {
        let clean = s.uppercased().filter { !$0.isWhitespace && $0 != "=" && $0 != "-" }
        guard !clean.isEmpty else { return nil }
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for ch in clean {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(idx)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for b in data {
            buffer = (buffer << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }
}
