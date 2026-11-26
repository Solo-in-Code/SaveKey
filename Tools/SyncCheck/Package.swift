// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Runs SaveKey's file-sync code (DatabaseSession, DatabaseLibrary, FileAccess) on Linux, with
// stand-ins for SwiftUI, Combine and Apple-only file APIs. Linux only: use ./run.sh.
import PackageDescription

let package = Package(
    name: "SyncCheck",
    dependencies: [.package(path: "../../Packages/KeePassCore")],
    targets: [
        .target(name: "Combine", path: "Stubs/Combine"),
        .target(name: "SwiftUI", path: "Stubs/SwiftUI"),
        .executableTarget(name: "AppLogic",
                          dependencies: ["Combine", "SwiftUI", .product(name: "KeePassCore", package: "KeePassCore")],
                          path: "Sources/AppLogic"),
    ]
)
