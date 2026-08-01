// swift-tools-version: 6.0
import PackageDescription

// The .app bundle is assembled by build.sh — SwiftPM only produces the two
// Mach-O executables that go inside it, plus the renderer they share.
let package = Package(
    name: "Imark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ImarkRender",
            path: "Sources/ImarkRender",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Imark",
            dependencies: ["ImarkRender"],
            path: "Sources/Imark",
            swiftSettings: [.swiftLanguageMode(.v5)]
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
