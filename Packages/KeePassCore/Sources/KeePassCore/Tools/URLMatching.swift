// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Matches entries to websites/domains, used by Password AutoFill.
public enum URLMatcher {
    /// Second-level labels that act like top-level domains (e.g. example.co.uk).
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "com.au", "net.au", "org.au", "edu.au",
        "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "co.kr", "com.br", "com.cn", "com.hk", "com.mx",
        "com.sg", "com.tr", "com.tw", "co.in", "co.za", "com.ar", "co.il", "com.pl", "com.ua", "co.id", "com.my",
    ]

    /// Extracts a lowercase host from a URL or bare domain string.
    public static func host(from string: String) -> String? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let host = URLComponents(string: s)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The registrable domain (eTLD+1), approximated.
    public static func baseDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return host } // IPv4
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    /// All URLs associated with an entry: URL plus KeePassXC / KeePass2Android additional URL fields.
    public static func urls(of entry: KPEntry) -> [String] {
        var result = [entry.url]
        for f in entry.fields where f.key.hasPrefix("KP2A_URL") || f.key.uppercased().hasPrefix("URL_") {
            result.append(f.value)
        }
        return result.filter { !$0.isEmpty }
    }

    public enum Quality: Int, Comparable {
        case none = 0, sameBaseDomain, subdomain, exactHost
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    public static func matchQuality(entry: KPEntry, serviceHost: String) -> Quality {
        let target = serviceHost.hasPrefix("www.") ? String(serviceHost.dropFirst(4)) : serviceHost.lowercased()
        var best = Quality.none
        for u in urls(of: entry) {
            guard let h = host(from: u) else { continue }
            let q: Quality
            if h == target {
                q = .exactHost
            } else if target.hasSuffix("." + h) || h.hasSuffix("." + target) {
                q = .subdomain
            } else if baseDomain(h) == baseDomain(target) {
                q = .sameBaseDomain
            } else {
                q = .none
            }
            best = max(best, q)
        }
        return best
    }

    /// Entries that match any of the given service identifiers (URLs or domains), best matches first.
    public static func matchingEntries(in db: Database, identifiers: [String]) -> [KPEntry] {
        let hosts = identifiers.compactMap(host(from:))
        guard !hosts.isEmpty else { return [] }
        let scored: [(KPEntry, Quality)] = db.searchableEntries.compactMap { e in
            let q = hosts.map { matchQuality(entry: e, serviceHost: $0) }.max() ?? .none
            return q == .none ? nil : (e, q)
        }
        return scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
        }.map(\.0)
    }
}
