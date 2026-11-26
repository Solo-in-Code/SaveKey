// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit
import KeePassCore

/// Maps the 69 standard KeePass icons to SF Symbols.
enum KeePassIcons {
    static let symbols: [String] = [
        "key.fill",                       // 0 Key
        "globe",                          // 1 World
        "exclamationmark.triangle.fill",  // 2 Warning
        "server.rack",                    // 3 Network server
        "pin.fill",                       // 4 Marked directory
        "bubble.left.and.bubble.right.fill", // 5 User communication
        "puzzlepiece.fill",               // 6 Parts
        "note.text",                      // 7 Notepad
        "network",                        // 8 World socket
        "person.text.rectangle.fill",     // 9 Identity
        "doc.text.fill",                  // 10 Paper ready
        "camera.fill",                    // 11 Digicam
        "antenna.radiowaves.left.and.right", // 12 IR communication
        "key.horizontal.fill",            // 13 Multi keys
        "bolt.fill",                      // 14 Energy
        "scanner.fill",                   // 15 Scanner
        "star.circle.fill",               // 16 World star
        "opticaldisc",                    // 17 CD-ROM
        "display",                        // 18 Monitor
        "envelope.fill",                  // 19 E-mail
        "gearshape.fill",                 // 20 Configuration
        "doc.on.clipboard.fill",          // 21 Clipboard ready
        "doc.badge.plus",                 // 22 Paper new
        "macwindow",                      // 23 Screen
        "bolt.trianglebadge.exclamationmark.fill", // 24 Energy careful
        "tray.full.fill",                 // 25 E-mail box
        "internaldrive.fill",             // 26 Disk
        "externaldrive.fill",             // 27 Drive
        "doc.text.magnifyingglass",       // 28 Paper Q
        "terminal.fill",                  // 29 Terminal encrypted
        "chevron.left.forwardslash.chevron.right", // 30 Console
        "printer.fill",                   // 31 Printer
        "square.grid.3x3.fill",           // 32 Program icons
        "play.rectangle.fill",            // 33 Run
        "wrench.and.screwdriver.fill",    // 34 Settings
        "desktopcomputer",                // 35 World computer
        "archivebox.fill",                // 36 Archive
        "creditcard.fill",                // 37 Home banking / credit card (as in KeePassDX)
        "externaldrive.connected.to.line.below.fill", // 38 Drive Windows
        "clock.fill",                     // 39 Clock
        "envelope.open.fill",             // 40 E-mail search
        "flag.fill",                      // 41 Paper flag
        "memorychip.fill",                // 42 Memory
        "trash.fill",                     // 43 Recycle bin
        "note",                           // 44 Note
        "xmark.circle.fill",              // 45 Expired
        "info.circle.fill",               // 46 Info
        "shippingbox.fill",               // 47 Package
        "folder.fill",                    // 48 Folder
        "folder",                         // 49 Folder open
        "archivebox",                     // 50 Folder package
        "lock.open.fill",                 // 51 Lock open
        "lock.doc.fill",                  // 52 Paper locked
        "checkmark.circle.fill",          // 53 Checked
        "pencil",                         // 54 Pen
        "photo.fill",                     // 55 Thumbnail
        "book.fill",                      // 56 Book
        "list.bullet",                    // 57 List
        "person.badge.key.fill",          // 58 User key
        "hammer.fill",                    // 59 Tool
        "house.fill",                     // 60 Home
        "star.fill",                      // 61 Star
        "pawprint.fill",                  // 62 Tux
        "leaf.fill",                      // 63 Feather
        "applelogo",                      // 64 Apple
        "w.circle.fill",                  // 65 Wiki
        "dollarsign.circle.fill",         // 66 Money
        "checkmark.seal.fill",            // 67 Certificate
        "candybarphone",                  // 68 BlackBerry
    ]

    static func symbol(for id: Int) -> String {
        symbols.indices.contains(id) ? symbols[id] : "key.fill"
    }
}

/// Renders an entry or group icon: a custom image if present, otherwise the standard icon.
/// Folders and entries share the same colours; `isGroup` is kept for callers that distinguish them.
struct KeePassIconView: View {
    var iconID: Int
    var customIcon: CustomIcon?
    var size: CGFloat = 30
    var isGroup = false
    var dimmed = false

    var body: some View {
        let image = customIcon.flatMap { UIImage(data: $0.data) }
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.78, height: size * 0.78)
            } else {
                Image(systemName: KeePassIcons.symbol(for: iconID))
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(Theme.iconSymbol)
            }
        }
        .frame(width: size, height: size)
        .background(tile(hasImage: image != nil), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .opacity(dimmed ? 0.45 : 1)
    }

    /// Built-in symbols (folders and entries alike) sit on a solid tile in the logo colours;
    /// custom images keep a neutral backdrop.
    private func tile(hasImage: Bool) -> Color {
        hasImage ? Color.primary.opacity(0.06) : Theme.iconTile
    }
}
