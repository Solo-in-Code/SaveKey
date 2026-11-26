// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "KeePassCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "KeePassCore", targets: ["KeePassCore"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "KeePassCore",
            dependencies: ["CZlib"],
            path: "Sources/KeePassCore",
            resources: [.copy("Resources/eff_large_wordlist.txt")],
            swiftSettings: [
                // Key derivation (Argon2 / AES-KDF) is far too slow without optimisation,
                // so the engine is always compiled optimised, even in Debug builds.
                .unsafeFlags(["-O"]),
            ]
        ),
        .testTarget(
            name: "KeePassCoreTests",
            dependencies: ["KeePassCore"],
            path: "Tests/KeePassCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
