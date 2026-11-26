// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import KeePassCore

/// Downloads a website's logo. Only the site's address is used (never the rest of the entry's URL),
/// always over HTTPS, without cookies, and with time and size limits.
actor WebsiteIconFetcher {
    struct Icon: Sendable {
        let png: Data
        /// The logo fills its square (e.g. an Apple touch icon), so it is shown edge to edge.
        let fullBleed: Bool
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "en",
        ]
        return URLSession(configuration: config)
    }()

    func fetch(host: String) async -> Icon? {
        if let icon = await fetchIcon(from: host) { return icon }
        let base = URLMatcher.baseDomain(host)
        if base != host { return await fetchIcon(from: base) }
        return nil
    }

    private func fetchIcon(from host: String) async -> Icon? {
        guard let root = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let page = await fetchPage(root) {
            candidates = WebsiteIcon.iconCandidates(html: page.html, baseURL: page.url)
        }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let url = URL(string: "https://\(host)\(path)"), !candidates.contains(url) { candidates.append(url) }
        }
        var best: CGImage?
        for url in candidates.prefix(6) {
            guard let image = await fetchImage(url) else { continue }
            if image.width > (best?.width ?? 0) { best = image }
            if image.width >= 120 { break }
        }
        guard let best, best.width >= 16 else { return nil }
        return Self.normalize(best)
    }

    /// Reads the page only up to the end of its <head> (where icons are declared), at most 300 KB.
    private func fetchPage(_ url: URL) async -> (html: String, url: URL)? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            data.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 300_000 { break }
                if data.count % 2048 == 0,
                   String(decoding: data.suffix(4096), as: UTF8.self).lowercased().contains("</head>") {
                    break
                }
            }
            return (String(decoding: data, as: UTF8.self), http.url ?? url)
        } catch {
            return nil
        }
    }

    private func fetchImage(_ url: URL) async -> CGImage? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count < 3_000_000 else { return nil }
            return Self.largestImage(in: data)
        } catch {
            return nil
        }
    }

    /// Decodes PNG/JPEG/GIF/ICO…; for .ico files with several sizes, takes the largest.
    static func largestImage(in data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            if let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width > (best?.width ?? 0) {
                best = image
            }
        }
        return best
    }

    /// Scales the logo into a 128×128 PNG and checks whether it fills the square.
    static func normalize(_ image: CGImage) -> Icon? {
        let side = 128
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(CGFloat(side) / w, CGFloat(side) / h)
        let rect = CGRect(x: (CGFloat(side) - w * scale) / 2, y: (CGFloat(side) - h * scale) / 2,
                          width: w * scale, height: h * scale)
        context.draw(image, in: rect)
        guard let output = context.makeImage() else { return nil }

        var fullBleed = false
        if image.width >= 57, let base = context.data {
            let rowBytes = context.bytesPerRow
            let bytes = base.bindMemory(to: UInt8.self, capacity: rowBytes * side)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * rowBytes + x * 4 + 3] }
            let near = 4
            let far = side - 5
            fullBleed = [alpha(near, near), alpha(far, near), alpha(near, far), alpha(far, far)].allSatisfy { $0 > 200 }
        }

        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Icon(png: png as Data, fullBleed: fullBleed)
    }
}

/// Website logos kept on this device (shared with the AutoFill extension when possible).
@MainActor
final class WebsiteIconStore: ObservableObject {
    static let shared = WebsiteIconStore()

    struct CachedIcon {
        let image: UIImage
        let fullBleed: Bool
    }

    @Published private(set) var icons: [String: CachedIcon] = [:]
    private var pending = Set<String>()
    private var failures: [String: Date] = [:]
    private let fetcher = WebsiteIconFetcher()
    private let directory: URL
    /// The AutoFill extension only shows icons the app has already downloaded.
    private let canDownload = Bundle.main.bundleURL.pathExtension != "appex"
    private static let retryAfter: TimeInterval = 3 * 24 * 3600

    init() {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("WebsiteIcons", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("failures.json")),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            failures = decoded
        }
    }

    private func fileURL(_ host: String, fullBleed: Bool) -> URL {
        directory.appendingPathComponent(fullBleed ? "\(host).full.png" : "\(host).png")
    }

    /// Shows the cached logo for `host`, or downloads it in the background. Safe to call repeatedly.
    func request(_ host: String) {
        guard icons[host] == nil, !pending.contains(host) else { return }
        for fullBleed in [true, false] {
            if let data = try? Data(contentsOf: fileURL(host, fullBleed: fullBleed)), let image = UIImage(data: data) {
                icons[host] = CachedIcon(image: image, fullBleed: fullBleed)
                return
            }
        }
        guard canDownload else { return }
        if let failed = failures[host], Date().timeIntervalSince(failed) < Self.retryAfter { return }
        pending.insert(host)
        Task {
            let icon = await fetcher.fetch(host: host)
            pending.remove(host)
            if let icon, let image = UIImage(data: icon.png) {
                try? icon.png.write(to: fileURL(host, fullBleed: icon.fullBleed), options: .atomic)
                icons[host] = CachedIcon(image: image, fullBleed: icon.fullBleed)
            } else {
                failures[host] = Date()
                saveFailures()
            }
        }
    }

    /// Deletes every downloaded logo.
    func clearCache() {
        icons = [:]
        failures = [:]
        pending = []
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func saveFailures() {
        if let data = try? JSONEncoder().encode(failures) {
            try? data.write(to: directory.appendingPathComponent("failures.json"), options: .atomic)
        }
    }
}

/// An entry's icon: custom icon if set, card badge for cards, the website's logo when
/// "Show website icons" is on, otherwise the standard KeePass icon.
struct EntryIconView: View {
    let entry: KPEntry
    var customIcon: CustomIcon?
    var size: CGFloat = 34
    /// Captured so the icon refreshes (and fetches a new logo) after the entry is edited.
    private let revision: Int

    init(entry: KPEntry, customIcon: CustomIcon? = nil, size: CGFloat = 34) {
        self.entry = entry
        self.customIcon = customIcon
        self.size = size
        self.revision = entry.displayRevision
    }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = WebsiteIconStore.shared

    var body: some View {
        let card = PaymentCard.from(entry: entry)
        let host = (settings.showWebsiteIcons && customIcon == nil && card == nil) ? WebsiteIcon.host(for: entry) : nil
        Group {
            if let card, customIcon == nil {
                CardBadge(brand: card.resolvedBrand, size: size, dimmed: entry.times.isExpired)
            } else if let host, let icon = store.icons[host] {
                WebsiteIconImage(icon: icon, size: size, dimmed: entry.times.isExpired)
            } else {
                KeePassIconView(iconID: entry.iconID, customIcon: customIcon, size: size, dimmed: entry.times.isExpired)
            }
        }
        .task(id: host) {
            if let host { store.request(host) }
        }
    }
}

struct WebsiteIconImage: View {
    let icon: WebsiteIconStore.CachedIcon
    var size: CGFloat = 34
    var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if icon.fullBleed {
                Image(uiImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image(uiImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.14)
                    .frame(width: size, height: size)
                    .background(Color.white, in: shape)
            }
        }
        .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}
