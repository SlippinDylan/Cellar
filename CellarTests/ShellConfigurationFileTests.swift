import Darwin
import XCTest
@testable import Cellar

final class ShellConfigurationFileTests: XCTestCase {
    func testNodeFingerprintReaderBoundsAndRefusesSpecialFilesWithoutLeakingDescriptors() async throws {
        let fixture = try FileReadProbe()
        defer { fixture.remove() }
        let fifo = fixture.root.appending(path: "fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let oversized = fixture.root.appending(path: "oversized")
        try Data(repeating: 32, count: 4097).write(to: oversized)
        let link = fixture.root.appending(path: "symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oversized)
        for file in [fifo, oversized, link, fixture.root, URL(filePath: "/dev/null")] {
            let result = try await fixture.run(mode: "node-read", source: file)
            XCTAssertEqual(result.terminationStatus, 0, result.errorText)
        }
        let regular = fixture.root.appending(path: "regular")
        try Data("v24.0.0\n".utf8).write(to: regular)
        let changed = try await fixture.run(mode: "node-replace", source: regular)
        XCTAssertEqual(changed.terminationStatus, 0, changed.errorText)
        XCTAssertNil(try NodeConfigurationFile.read(at: fixture.root.appending(path: "absent"), maximumBytes: 4096))
    }

    func testFIFOWithoutWriterRejectsPromptlyAndDoesNotLeakDescriptors() async throws {
        let fixture = try FileReadProbe()
        defer { fixture.remove() }
        let fifo = fixture.root.appending(path: "fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        do {
            let result = try await fixture.run(mode: "read", source: fifo)
            XCTAssertEqual(result.terminationStatus, 0, result.errorText)
        } catch {
            XCTFail("FIFO without any writer must refuse immediately: \(error)")
        }
    }

    func testReplacementAndOtherNonRegularFilesRefuseWithoutMutation() async throws {
        let fixture = try FileReadProbe()
        defer { fixture.remove() }
        let original = fixture.root.appending(path: "original")
        try Data("original\n".utf8).write(to: original)
        let replacement = fixture.root.appending(path: "replacement")
        XCTAssertEqual(mkfifo(replacement.path, 0o600), 0)
        let result = try await fixture.run(mode: "restore", source: original, target: replacement)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: original), Data("original\n".utf8))
        for candidate in [fixture.root, URL(filePath: "/dev/null")] {
            let refused = try await fixture.run(mode: "read", source: candidate)
            XCTAssertEqual(refused.terminationStatus, 0)
        }
        let changed = try await fixture.run(mode: "replace-read", source: original)
        XCTAssertEqual(changed.terminationStatus, 0)
        var metadata = stat()
        XCTAssertEqual(lstat(original.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFIFO)
        let socket = try await fixture.run(mode: "socket", source: original)
        XCTAssertEqual(socket.terminationStatus, 0)
    }
}

private struct FileReadProbe {
    let root: URL
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CellarFileProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appending(path: "probe")
    }
    func run(mode: String, source: URL, target: URL? = nil) async throws -> ProcessResult {
        let runner = ProcessRunner()
        let environment = ShellEnvironmentResolver(homeDirectory: root, temporaryDirectory: root).environment()
        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            let main = root.appending(path: "main.swift")
            let program = #"""
            import Darwin
            import Foundation
            let arguments = CommandLine.arguments
            var candidate = URL(filePath: arguments[2])
            var sockets: [Int32] = [-1, -1]
            if arguments[1] == "replace-read" {
                _ = try ShellConfigurationFile.read(at: candidate)
                guard unlink(candidate.path) == 0, mkfifo(candidate.path, 0o600) == 0 else { exit(5) }
            }
            if arguments[1] == "node-replace" {
                _ = try NodeConfigurationFile.read(at: candidate, maximumBytes: 4096)
                guard unlink(candidate.path) == 0, mkfifo(candidate.path, 0o600) == 0 else { exit(5) }
            }
            if arguments[1] == "socket" {
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { exit(5) }
                candidate = URL(filePath: "/dev/fd/\(sockets[0])")
            }
            let available = open("/dev/null", O_RDONLY | O_CLOEXEC)
            close(available)
            for _ in 0..<100 {
                do {
                    if arguments[1].hasPrefix("node-") { _ = try NodeConfigurationFile.read(at: candidate, maximumBytes: 4096) }
                    else if arguments[1] != "restore" { _ = try ShellConfigurationFile.read(at: candidate) }
                    else {
                        let original = try ShellConfigurationFile.read(at: URL(filePath: arguments[2]))
                        try original.restore(at: URL(filePath: arguments[3]), replacing: original.contents)
                    }
                    exit(2)
                } catch BridgeError.managerFailure { }
                catch { exit(3) }
            }
            let after = open("/dev/null", O_RDONLY | O_CLOEXEC)
            close(after)
            for descriptor in sockets where descriptor >= 0 { close(descriptor) }
            exit(after == available ? 0 : 4)
            """#
            try Data(program.utf8).write(to: main)
            let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let compile = try await runner.run(ProcessRequest(executableURL: URL(filePath: "/usr/bin/xcrun"),
                                                              arguments: ["swiftc", repository.appending(path: "Bridge/ShellConfigurationFile.swift").path,
                                                                          repository.appending(path: "Bridge/NodeConfigurationFile.swift").path,
                                                                          repository.appending(path: "Bridge/BridgeError.swift").path, main.path, "-target", "arm64-apple-macos26.0", "-o", executable.path],
                                                              environment: environment, currentDirectoryURL: root, timeout: .seconds(60)))
            XCTAssertEqual(compile.terminationStatus, 0, compile.errorText)
        }
        return try await runner.run(ProcessRequest(executableURL: executable, arguments: [mode, source.path] + (target.map { [$0.path] } ?? []),
                                                   environment: environment, currentDirectoryURL: root, timeout: .seconds(2)))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
