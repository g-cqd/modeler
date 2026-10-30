import Foundation
import Testing

/// modeler on analyzerkit's shared option groups (ADR-0019, roadmap 0022): `check` takes Input, Output, Rules and Cache
/// and gains formats, a configuration file, baselines and suppression; the diagram commands take Input and Cache.
@Suite(.serialized) struct CommandLineSurfaceTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// One reentrancy warning, its write at line 6.
    private static func reentrant(_ name: String) -> String {
        "actor \(name) {\n    var value = 0\n    func bump() async {\n        if value == 0 {\n            await work()\n"
            + "            value = 1\n        }\n    }\n    func work() async {}\n}\n"
    }

    struct Run {
        let status: Int32
        let output: String
        let errors: String
    }

    private static func executable() throws -> URL {
        let build = packageRoot.appending(path: ".build")
        let candidates = ["debug", "release"].map { build.appending(path: "\($0)/modeler") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate]
                as? Date ?? .distantPast
        }
        return try #require(candidates.max { modified($0) < modified($1) }, "build modeler first")
    }

    private static func run(_ arguments: [String], in root: URL) throws -> Run {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
            errors: String(decoding: err, as: UTF8.self))
    }

    private static func workspace(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "modeler-cli-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("gitdir: none\n".utf8).write(to: root.appending(path: ".git"))
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try body(root)
    }

    @Test func `check's help lists every shared option, the diagrams' only Input and Cache`() throws {
        try Self.workspace([:]) { root in
            let check = try Self.run(["check", "--help"], in: root).output
            for option in [
                "--config", "--exclude-path", "--include-regions", "--exclude-regions", "--define", "--only",
                "--only-from", "--format", "--relative-to", "--strict", "--baseline", "--write-baseline",
                "--report-new-since", "--verbose", "--quiet", "--timings", "--rules", "--cache-path", "--no-cache",
            ] {
                #expect(check.contains(option), "check is missing \(option)")
            }
            let classes = try Self.run(["classes", "--help"], in: root).output
            #expect(classes.contains("--exclude-path") && classes.contains("--cache-path"))
            #expect(!classes.contains("--format") && !classes.contains("--baseline"))
        }
    }

    @Test func `JSON and SARIF reports carry the finding with its rule and fingerprint`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A")]) { root in
            let json = try Self.run(["check", ".", "--no-cache", "--format", "json"], in: root)
            #expect(json.output.contains(#""rule" : "reentrancy""#))
            #expect(json.output.contains(#""fingerprint""#))
            #expect(json.output.contains(#""tool" : "modeler""#))
            let sarif = try Self.run(["check", ".", "--no-cache", "--format", "sarif"], in: root)
            #expect(sarif.output.contains(#""ruleId" : "reentrancy""#))
            #expect(sarif.output.contains(#""modeler/v1""#))
        }
    }

    @Test func `a baseline written once leaves the finding out the next time`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A")]) { root in
            #expect(try Self.run(["check", ".", "--no-cache", "--write-baseline", "b.json"], in: root).status == 0)
            let run = try Self.run(["check", ".", "--no-cache", "--baseline", "b.json", "--strict"], in: root)
            #expect(run.status == 0)
            #expect(run.output.isEmpty)
        }
    }

    @Test func `a modeler comment suppresses the finding on its line`() throws {
        let source = Self.reentrant("A").replacingOccurrences(
            of: "            value = 1\n",
            with: "            value = 1  // @modeler:accept reentrancy -- checked by the caller\n")
        try Self.workspace(["Sources/A.swift": source]) { root in
            let run = try Self.run(["check", ".", "--no-cache", "--strict"], in: root)
            #expect(run.status == 0)
            #expect(run.output.isEmpty)
            #expect(run.errors.contains("1 suppressed"))
        }
    }

    @Test func `a configuration file turns a rule off, and --rules chooses rules`() throws {
        try Self.workspace([
            "Sources/A.swift": Self.reentrant("A"), ".modeler.json": #"{"disable": ["reentrancy"]}"#,
        ]) { root in
            #expect(try Self.run(["check", ".", "--no-cache"], in: root).output.isEmpty)
            let chosen = try Self.run(["check", ".", "--no-cache", "--rules", "lock-gap"], in: root)
            #expect(chosen.output.isEmpty)
            let unknown = try Self.run(["check", ".", "--no-cache", "--rules", "nope"], in: root)
            #expect(unknown.status == 64)
        }
    }

    @Test func `exclude-path and the configuration's exclude leave files out of every command`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A"), "Sources/B.swift": Self.reentrant("B")]) { root in
            let check = try Self.run(["check", ".", "--no-cache", "--exclude-path", "B.swift"], in: root)
            #expect(check.output.contains("A.swift") && !check.output.contains("B.swift"))
            let classes = try Self.run(["classes", ".", "--no-cache", "--exclude-path", "B.swift"], in: root)
            #expect(classes.output.contains("class A") && !classes.output.contains("class B"))
        }
    }

    @Test func `include-tests still works with a note, and equals include-regions test,generated`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A"), "Tests/T.swift": Self.reentrant("T")]) { root in
            let old = try Self.run(["check", ".", "--no-cache", "--include-tests"], in: root)
            let new = try Self.run(["check", ".", "--no-cache", "--include-regions", "test,generated"], in: root)
            #expect(old.output.contains("T.swift"))
            #expect(old.output == new.output)
            #expect(
                old.errors.contains(
                    "modeler: note: --include-tests is deprecated; use --include-regions test,generated"))
        }
    }

    @Test func `report-new-since reports what the base baseline lacks outside --only`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A"), "Sources/C.swift": "let c = 1\n"]) { root in
            #expect(try Self.run(["check", ".", "--no-cache", "--write-baseline", "base.json"], in: root).status == 0)
            try Data(Self.reentrant("B").utf8).write(to: root.appending(path: "Sources/B.swift"))
            let run = try Self.run(
                ["check", ".", "--no-cache", "--only", "Sources/C.swift", "--report-new-since", "base.json"], in: root)
            #expect(run.output.contains("B.swift") && !run.output.contains("A.swift"))
            #expect(run.errors.contains("1 finding(s) outside --only are new since base.json"))
        }
    }

    @Test func `relative-to, quiet, verbose and timings`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A")]) { root in
            let relative = try Self.run(["check", ".", "--no-cache", "--relative-to", "."], in: root)
            #expect(relative.output.hasPrefix("Sources/A.swift:6:1: warning: [reentrancy]"))
            #expect(try Self.run(["check", ".", "--no-cache", "--quiet"], in: root).errors.isEmpty)
            let verbose = try Self.run(["check", ".", "--no-cache", "--verbose"], in: root)
            #expect(verbose.errors.contains("modeler: configuration: no file found; built-in defaults"))
            let timed = try Self.run(["check", ".", "--no-cache", "--format", "json", "--timings"], in: root)
            #expect(timed.output.contains(#""timings""#))
        }
    }

    @Test func `define is accepted and says it has no effect yet`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A")]) { root in
            let run = try Self.run(["check", ".", "--no-cache", "--define", "DEBUG"], in: root)
            #expect(run.errors.contains("modeler: note: --define has no effect yet: modeler reads every #if clause"))
        }
    }

    @Test func `rules lists the rules and explains one`() throws {
        try Self.workspace([:]) { root in
            let all = try Self.run(["rules"], in: root)
            #expect(all.output.contains("reentrancy") && all.output.contains("lock-gap"))
            let one = try Self.run(["rules", "lock-gap"], in: root)
            #expect(one.status == 0 && one.output.contains("lock"))
            #expect(try Self.run(["explain", "lock-gap"], in: root).output == one.output)
        }
    }

    @Test func `the cache lives under cache-path and is reused`() throws {
        try Self.workspace(["Sources/A.swift": Self.reentrant("A")]) { root in
            let cache = root.appending(path: "cache").path
            _ = try Self.run(["check", ".", "--cache-path", cache], in: root)
            let warm = try Self.run(["check", ".", "--cache-path", cache], in: root)
            #expect(warm.errors.contains("cache: 1 reused, 0 parsed"))
        }
    }

    @Test func `a test target outside Tests is test code`() throws {
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "P", targets: [
                .target(name: "Lib", path: "Lib"), .testTarget(name: "Checks", dependencies: ["Lib"], path: "Checks"),
            ])
            """
        try Self.workspace([
            "Package.swift": manifest, "Lib/A.swift": Self.reentrant("A"), "Checks/C.swift": Self.reentrant("C"),
        ]) { root in
            let run = try Self.run(["check", ".", "--no-cache"], in: root)
            #expect(run.output.contains("A.swift") && !run.output.contains("C.swift"))
        }
    }
}
