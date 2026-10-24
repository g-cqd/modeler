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
            revision: "6bca1d8fade0236506726869fb626c4882fc2aea"
        ),
        // The project model the analyzers share: test code and generated files are not modeled.
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "6f2ac674dfde1e5e37ecba22009a25336eb92280"
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
