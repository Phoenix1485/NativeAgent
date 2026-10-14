// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NativeAgent", targets: ["NativeAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "CSQLite"),
        .executableTarget(
            name: "NativeAgent",
            dependencies: ["CSQLite", .product(name: "Sparkle", package: "Sparkle")],
            path: "NativeAgent",
            exclude: ["Resources"],
            resources: [.copy("Web")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "NativeAgentTests",
            dependencies: ["NativeAgent", "CSQLite"],
            path: "NativeAgentTests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
