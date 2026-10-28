// swift-tools-version: 6.4
import PackageDescription

// Strict-by-default, as in the analyzers that share analyzerkit: warnings are
// errors, upcoming features are on, and strict memory safety keeps the unsafe
// surface at zero. Swift 6 language mode includes complete strict concurrency.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "modeler",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ModelerCore", targets: ["ModelerCore"]),
        .executable(name: "modeler", targets: ["modeler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        // The JSON coder for the facts report, and for the facts cache through analyzerkit.
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "5542d37ff0edb17c822b48fe69bff6e792354c57"
        ),
        // The project model the analyzers share: test code and generated files are not modeled.
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "3d1f8114c156d692333e89337fc990016b639b8d"
        ),
    ],
    targets: [
        .target(
            name: "ModelerCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "AemiJSON", package: "AemiJSON"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "modeler",
            dependencies: [
                "ModelerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ModelerCoreTests",
            dependencies: [
                "ModelerCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
