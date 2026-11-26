// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Decides which website an entry's logo comes from, and finds icon links in a web page.
/// Pure logic (no networking), so it can be unit-tested; the app does the downloading.
public enum WebsiteIcon {
    /// Popular services recognised by the entry title when the entry has no web address.
    static let knownServices: [String: String] = [
        "netflix": "netflix.com", "spotify": "spotify.com", "amazon": "amazon.com", "primevideo": "primevideo.com",
        "google": "google.com", "gmail": "mail.google.com", "youtube": "youtube.com", "facebook": "facebook.com",
        "instagram": "instagram.com", "whatsapp": "whatsapp.com", "twitter": "x.com", "x": "x.com",
        "linkedin": "linkedin.com", "microsoft": "microsoft.com", "outlook": "outlook.com", "hotmail": "outlook.com",
        "office365": "office.com", "apple": "apple.com", "appleid": "appleid.apple.com", "icloud": "icloud.com",
        "paypal": "paypal.com", "dropbox": "dropbox.com", "github": "github.com", "gitlab": "gitlab.com",
        "reddit": "reddit.com", "steam": "steampowered.com", "disney": "disneyplus.com", "disneyplus": "disneyplus.com",
        "hbomax": "max.com", "max": "max.com", "uber": "uber.com", "airbnb": "airbnb.com", "booking": "booking.com",
        "ebay": "ebay.com", "adobe": "adobe.com", "zoom": "zoom.us", "slack": "slack.com", "discord": "discord.com",
        "twitch": "twitch.tv", "tiktok": "tiktok.com", "pinterest": "pinterest.com", "yahoo": "yahoo.com",
        "protonmail": "proton.me", "proton": "proton.me", "telegram": "telegram.org", "signal": "signal.org",
        "aliexpress": "aliexpress.com", "nintendo": "nintendo.com", "playstation": "playstation.com",
        "xbox": "xbox.com", "epicgames": "epicgames.com", "revolut": "revolut.com", "wise": "wise.com",
        "binance": "binance.com", "coinbase": "coinbase.com", "duolingo": "duolingo.com", "canva": "canva.com",
        "notion": "notion.so", "trello": "trello.com", "atlassian": "atlassian.com", "bitbucket": "bitbucket.org",
        "mega": "mega.nz", "onedrive": "onedrive.live.com", "skype": "skype.com", "vinted": "vinted.com",
        "olx": "olx.com", "mercadolivre": "mercadolivre.com.br", "mercadolibre": "mercadolibre.com",
        "nubank": "nubank.com.br", "ifood": "ifood.com.br", "glovo": "glovoapp.com", "boltfood": "bolt.eu",
        "bolt": "bolt.eu", "deezer": "deezer.com", "crunchyroll": "crunchyroll.com", "hulu": "hulu.com",
        "paramountplus": "paramountplus.com", "appletv": "tv.apple.com", "chatgpt": "chatgpt.com",
        "openai": "openai.com", "claude": "claude.ai", "anthropic": "anthropic.com",
    ]

    private static let localSuffixes = [
        ".local", ".lan", ".home", ".internal", ".intranet", ".corp", ".localhost", ".localdomain",
        ".test", ".example", ".invalid", ".home.arpa", ".private",
    ]

    /// The website whose logo represents this entry, or nil (no web address, or a local/private host).
    public static func host(for entry: KPEntry) -> String? {
        for url in URLMatcher.urls(of: entry) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("://"),
               let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(),
               scheme != "http" && scheme != "https" {
                continue // app links, cmd://, ssh:// …
            }
            if let host = URLMatcher.host(from: trimmed), isPublicHost(host) { return host }
        }
        let key = entry.title.lowercased().filter { $0.isLetter || $0.isNumber }
        return knownServices[key]
    }

    /// True for ordinary internet domains; false for IP addresses, localhost and private network names,
    /// which are never contacted.
    public static func isPublicHost(_ host: String) -> Bool {
        let h = host.lowercased()
        guard h.contains("."), !h.hasPrefix("."), !h.hasSuffix("."), h != "localhost", !h.contains(":") else {
            return false
        }
        let labels = h.split(separator: ".")
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false } // IPv4 address
        if localSuffixes.contains(where: { h.hasSuffix($0) }) { return false }
        guard h.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." }),
              let tld = labels.last, tld.count >= 2, tld.contains(where: \.isLetter) else { return false }
        return true
    }

    /// Icon URLs declared in a page's <head>, best first: Apple touch icons and large icons before
    /// small favicons. SVG icons are skipped (they can't be shown as bitmaps).
    public static func iconCandidates(html: String, baseURL: URL) -> [URL] {
        var head = html
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            head = String(html[..<end.lowerBound])
        }
        var found: [(url: URL, score: Int, declared: Bool, order: Int)] = []
        for (order, tag) in matches(#"<link\b[^>]*>"#, in: head).enumerated() {
            let attrs = attributes(of: tag)
            let rel = (attrs["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let isTouch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard isTouch || rel.contains("icon"), !rel.contains("mask-icon") else { continue }
            guard var href = attrs["href"], !href.isEmpty else { continue }
            href = decodeEntities(href)
            let type = (attrs["type"] ?? "").lowercased()
            let path = href.lowercased().split(separator: "?").first.map(String.init) ?? ""
            if type.contains("svg") || path.hasSuffix(".svg") || href.lowercased().hasPrefix("data:") { continue }
            guard var url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            if url.scheme?.lowercased() == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.scheme = "https"
                url = c.url ?? url
            }
            guard url.scheme?.lowercased() == "https" else { continue }
            var size = isTouch ? 180 : (path.hasSuffix(".ico") ? 32 : 48)
            var declared = false
            if let sizes = attrs["sizes"]?.lowercased() {
                let values = sizes.split(whereSeparator: \.isWhitespace).compactMap { s -> Int? in
                    s.split(separator: "x").first.flatMap { Int($0) }
                }
                if let largest = values.max() {
                    size = largest
                    declared = true
                }
            }
            // Prefer about 180 px: bigger than 512 is unnecessary, smaller looks blurry.
            let score = size <= 512 ? size : 512 - (size - 512) / 8
            found.append((url, score, declared, order))
        }
        var seen = Set<URL>()
        return found
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.declared != b.declared { return a.declared } // a stated size beats a guess
                return a.order < b.order
            }
            .map(\.url)
            .filter { seen.insert($0).inserted }
    }

    // MARK: Helpers

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func attributes(of tag: String) -> [String: String] {
        let pattern = #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = tag as NSString
        var result: [String: String] = [:]
        for m in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for i in 2...4 where m.range(at: i).location != NSNotFound {
                value = ns.substring(with: m.range(at: i))
                break
            }
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
