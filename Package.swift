// swift-tools-version: 6.0
import PackageDescription

// The .app bundle is assembled by build.sh — SwiftPM only produces the two
// Mach-O executables that go inside it, plus the renderer they share.
let package = Package(
    name: "Imark",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned because this framework installs executable code. Updating it
        // is a deliberate review, not something a release build decides.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "ImarkRender",
            path: "Sources/ImarkRender",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Imark",
            dependencies: [
                "ImarkRender",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Imark",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The executable sits in Contents/MacOS; Sparkle is embedded in
            // the standard sibling Frameworks directory by build.sh.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
            ])]
        ),
        .executableTarget(
            name: "ImarkQuickLook",
            dependencies: ["ImarkRender"],
            path: "Sources/ImarkQuickLook",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // App extensions are entered through NSExtensionMain rather than
            // being started at main(), so the entry point moves.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
)
