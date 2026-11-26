// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Recognises the copies sync tools leave next to a file when two devices changed it before syncing:
/// - rclone bisync: `Passwords.kdbx.conflict1`, `Passwords.conflict1.kdbx` (with `--suffix-keep-extension`),
///   `Passwords.kdbx.path1` and the older `Passwords.kdbx..path1`;
/// - Syncthing: `Passwords.sync-conflict-20251124-101530-ABCDEFG.kdbx`;
/// - Dropbox and Nextcloud: `Passwords (Alex's conflicted copy 2025-11-24).kdbx`.
public enum SyncConflictCopies {
    /// Whether `candidate`, a file in the same folder, is a conflict copy of `fileName`.
    public static func isConflictCopy(_ candidate: String, of fileName: String) -> Bool {
        guard !fileName.isEmpty, candidate != fileName else { return false }
        let ext = (fileName as NSString).pathExtension
        let base = ext.isEmpty ? fileName : String(fileName.dropLast(ext.count + 1))

        // Suffix after the whole name: rclone bisync, or Syncthing for files without an extension.
        if candidate.count > fileName.count + 1, candidate.hasPrefix(fileName + ".") {
            let rest = candidate.dropFirst(fileName.count + 1)
            if matches(rest, bisyncSuffix) || (ext.isEmpty && matches(rest, syncthingSuffix)) { return true }
        }

        // Marker between the name and the extension: rclone bisync with --suffix-keep-extension, Syncthing.
        if !ext.isEmpty, candidate.count > base.count + ext.count + 2,
           candidate.hasPrefix(base + "."), candidate.hasSuffix("." + ext) {
            let middle = candidate.dropFirst(base.count + 1).dropLast(ext.count + 1)
            if matches(middle, bisyncSuffix) || matches(middle, syncthingSuffix) { return true }
        }

        // Dropbox, Nextcloud and others: "Name (… conflicted copy …).ext", in several languages.
        let tail = ext.isEmpty ? ")" : ")." + ext
        if candidate.count > base.count + 2 + tail.count, candidate.hasPrefix(base + " ("), candidate.hasSuffix(tail) {
            let inside = candidate.dropFirst(base.count + 2).dropLast(tail.count).lowercased()
            if inside.contains("confli") || inside.contains("konflikt") { return true }
        }
        return false
    }

    /// The real name behind an iCloud placeholder for a file that is not downloaded
    /// (`.Passwords.kdbx.icloud` → `Passwords.kdbx`), or nil for other names.
    public static func realName(ofPlaceholder name: String) -> String? {
        guard name.count > 8, name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    private static let bisyncSuffix = #"^(\.?path[12]|[A-Za-z0-9_.{}-]*conflict[0-9]*)$"#
    private static let syncthingSuffix = #"^sync-conflict-[0-9]{8}-[0-9]{6}-[A-Za-z0-9]+$"#

    private static func matches(_ text: Substring, _ pattern: String) -> Bool {
        let s = String(text)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
