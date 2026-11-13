import XCTest
@testable import Cellar

final class ProcessRunnerTests: XCTestCase {
    func testKeepsStandardOutputAndErrorSeparate() async throws {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "cellar-process-runner-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nprintf output\nprintf error >&2\nexit 7\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let runner = ProcessRunner()
        let result = try await runner.run(ProcessRequest(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: nil
        ))

        XCTAssertEqual(result.outputText, "output")
        XCTAssertEqual(result.errorText, "error")
        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertFalse(result.standardOutputWasTruncated)
        XCTAssertFalse(result.standardErrorWasTruncated)
    }

    func testBoundsEachCapturedStreamAndContinuesDraining() async throws {
        let script = try makeScript(
            "#!/bin/sh\ni=0\nwhile [ $i -lt 10000 ]; do\n  printf 1234567890\n  printf abcdefghij >&2\n  i=$((i + 1))\ndone\n"
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: nil,
            standardOutputLimit: 4,
            standardErrorLimit: 6
        ))

        XCTAssertEqual(result.outputText, "1234")
        XCTAssertEqual(result.errorText, "abcdef")
        XCTAssertTrue(result.standardOutputWasTruncated)
        XCTAssertTrue(result.standardErrorWasTruncated)
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testTerminatesProcessAndThrowsWhenTimeoutExpires() async throws {
        let script = try makeScript("#!/bin/sh\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProcessRunner().run(ProcessRequest(
                executableURL: script,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: nil,
                timeout: .milliseconds(100)
            ))
            XCTFail("Expected the process to time out")
        } catch let error as BridgeError {
            guard case .processTimedOut(let executable) = error else {
                return XCTFail("Unexpected bridge error: \(error)")
            }
            XCTAssertEqual(executable, script.lastPathComponent)
        }
    }

    func testCancellationTerminatesProcessAndThrowsCancellation() async throws {
        let script = try makeScript("#!/bin/sh\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessRunner()
        let start = ContinuousClock.now
        let task = Task {
            try await runner.run(ProcessRequest(
                executableURL: script,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: nil
            ))
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testCleansUpDescendantThatOutlivesNormallyExitedParent() async throws {
        let script = try makeScript(
            "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 1; done' &\nexit 0\n"
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let start = ContinuousClock.now

        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: nil
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testTimeoutTerminatesDescendantThatIgnoresTermAndKeepsPipeOpen() async throws {
        let script = try makeScript(
            "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 1; done' &\nwait\n"
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let start = ContinuousClock.now

        do {
            _ = try await ProcessRunner().run(ProcessRequest(
                executableURL: script,
                arguments: [],
                environment: [
                    "PATH": "/usr/bin:/bin",
                ],
                currentDirectoryURL: nil,
                timeout: .milliseconds(500)
            ))
            XCTFail("Expected the process tree to time out")
        } catch let error as BridgeError {
            guard case .processTimedOut = error else {
                return XCTFail("Unexpected bridge error: \(error)")
            }
        }

        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testTerminateAllStopsConcurrentProcessGroups() async throws {
        let script = try makeScript("#!/bin/sh\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessRunner()
        let start = ContinuousClock.now
        let tasks = (0..<3).map { _ in
            Task {
                try await runner.run(ProcessRequest(
                    executableURL: script,
                    arguments: [],
                    environment: ["PATH": "/usr/bin:/bin"],
                    currentDirectoryURL: nil
                ))
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        await runner.terminateAll()
        var results: [ProcessResult] = []
        for task in tasks {
            results.append(try await task.value)
        }

        XCTAssertTrue(results.allSatisfy { $0.terminationStatus != 0 })
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testSpawnFailureDoesNotLeakPipeDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarProcessDescriptorProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "DescriptorProbe.swift")
        let executable = root.appending(path: "probe")
        // A hosted async test cannot attribute the entire App's descriptor changes to this runner.
        let program = #"""
        import Darwin
        import Foundation

        @main enum DescriptorProbe {
            static func descriptors() throws -> [Int32: UInt32] {
                let required = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
                guard required > 0 else { throw POSIXError(.EIO) }
                let stride = MemoryLayout<proc_fdinfo>.stride
                var records = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / stride + 16)
                let bytes = records.withUnsafeMutableBytes {
                    proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                }
                guard bytes > 0, Int(bytes) < records.count * stride, Int(bytes) % stride == 0 else {
                    throw POSIXError(.EIO)
                }
                return Dictionary(uniqueKeysWithValues: records.prefix(Int(bytes) / stride).map {
                    ($0.proc_fd, $0.proc_fdtype)
                })
            }

            static func main() async throws {
                let runner = ProcessRunner()
                let before = try descriptors()
                for attempt in 1...100 {
                    do {
                        _ = try await runner.run(ProcessRequest(
                            executableURL: URL(filePath: "/path/that/does/not/exist"),
                            arguments: [], environment: [:], currentDirectoryURL: nil
                        ))
                        print("Attempt \(attempt): missing executable unexpectedly started")
                        exit(2)
                    } catch let error as NSError {
                        guard error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) else { throw error }
                    }
                    let after = try descriptors()
                    guard after == before else {
                        let added = after.filter { before[$0.key] != $0.value }
                        let removed = before.filter { after[$0.key] != $0.value }
                        print("Attempt \(attempt): added descriptors/types=\(added); removed=\(removed)")
                        exit(3)
                    }
                }
                print("Verified 100 failed spawns without descriptor changes")
            }
        }
        """#
        try Data(program.utf8).write(to: source)
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let environment = ShellEnvironmentResolver(homeDirectory: root, temporaryDirectory: root).environment()
        let runner = ProcessRunner()
        let compile = try await runner.run(ProcessRequest(executableURL: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-swift-version", "6", "-parse-as-library",
                        repository.appending(path: "Bridge/ProcessRunner.swift").path,
                        repository.appending(path: "Bridge/BridgeError.swift").path, source.path,
                        "-target", "arm64-apple-macos26.0", "-o", executable.path],
            environment: environment, currentDirectoryURL: root, timeout: .seconds(60)))
        XCTAssertEqual(compile.terminationStatus, 0, compile.errorText)
        guard compile.terminationStatus == 0 else { return }
        let result = try await runner.run(ProcessRequest(executableURL: executable, arguments: [],
            environment: environment, currentDirectoryURL: root, timeout: .seconds(5)))
        XCTAssertEqual(result.terminationStatus, 0, result.outputText + result.errorText)
    }

    private func makeScript(_ contents: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "cellar-process-runner-\(UUID().uuidString).sh")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
