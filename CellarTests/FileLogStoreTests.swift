import Darwin
import XCTest
@testable import Cellar

@MainActor
final class FileLogStoreTests: XCTestCase {
    func testFilteringDefaultsAndPersistedSettingsApplyImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        XCTAssertEqual(store.minimumLevel, .info)
        XCTAssertEqual(store.retention, .sevenDays)
        store.record(level: .debug, category: "test", message: "filtered debug")
        store.record(level: .info, category: "test", message: "recorded info")
        store.minimumLevel = .error
        store.record(level: .warning, category: "test", message: "filtered warning")
        store.record(level: .error, category: "test", message: "recorded error")
        store.retention = .fourteenDays
        await store.flush()
        let text = try fixture.text()
        XCTAssertFalse(text.contains("filtered"))
        XCTAssertTrue(text.contains("recorded info"))
        XCTAssertTrue(text.contains("recorded error"))
        let restored = fixture.store()
        XCTAssertEqual(restored.minimumLevel, .error)
        XCTAssertEqual(restored.retention, .fourteenDays)
        XCTAssertNil(store.errorMessage)
    }

    func testInvalidPreferencesUseSupportedDefaultsWithoutCreatingFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set("invalid", forKey: FileLogStore.minimumLevelKey)
        fixture.defaults.set(999, forKey: FileLogStore.retentionKey)
        let store = fixture.store()
        XCTAssertEqual(store.minimumLevel, .info)
        XCTAssertEqual(store.retention, .sevenDays)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testCrossingMidnightCreatesANewFileWithoutRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock(date: Date(timeIntervalSince1970: 1_700_006_399))
        let store = fixture.store(now: { clock.date })
        store.record(level: .info, category: "task", message: "before midnight")
        clock.date = clock.date.addingTimeInterval(2)
        store.record(level: .info, category: "task", message: "after midnight")
        await store.flush()
        let files = try fixture.logFiles()
        XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files[0].lastPathComponent, files[1].lastPathComponent)
        XCTAssertTrue(try fixture.text().contains("before midnight"))
        XCTAssertTrue(try fixture.text().contains("after midnight"))
    }

    func testSizeRotationAndTotalLimitKeepRecentCompleteUTF8Entries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(maximumFileBytes: 256, maximumTotalBytes: 768)
        for index in 0..<10 {
            store.record(level: .info, category: "task", message: "entry-\(index) " + String(repeating: "界", count: 100))
        }
        await store.flush()
        let files = try fixture.logFiles()
        XCTAssertEqual(files.count, 3)
        var total = 0
        for file in files {
            let data = try Data(contentsOf: file)
            total += data.count
            XCTAssertLessThanOrEqual(data.count, 256)
            XCTAssertNotNil(String(data: data, encoding: .utf8))
            XCTAssertEqual(data.last, 0x0A)
        }
        XCTAssertLessThanOrEqual(total, 768)
        let text = try fixture.text()
        XCTAssertTrue(text.contains("entry-9"))
        XCTAssertFalse(text.contains("entry-0"))
        XCTAssertNil(store.errorMessage)
    }

    func testRetentionChangeCleansOwnedOldFilesAndPreservesUnrelatedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let store = fixture.store(now: { clock.date })
        store.retention = .thirtyDays
        store.record(level: .info, category: "test", message: "older entry")
        await store.flush()
        let olderFile = try XCTUnwrap(fixture.logFiles().first)
        let unrelated = store.directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        clock.date = clock.date.addingTimeInterval(10 * 86_400)
        store.record(level: .info, category: "test", message: "recent entry")
        await store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderFile.path))
        store.retention = .sevenDays
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderFile.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        XCTAssertEqual(try fixture.logFiles().count, 1)
        XCTAssertTrue(try fixture.text().contains("recent entry"))
    }

    func testLogsSanitizeSecretsPrivatePathsAndNewlineInjection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let id = UUID()
        store.record(level: .error, category: "provider\nforged", message: "token=private-token /Users/alice/private/file\nforged log", taskID: id)
        store.record(level: .info, category: "provider", message: "https://alice:private-password@example.com/repo")
        await store.flush()
        let text = try fixture.text()
        XCTAssertFalse(text.contains("private-token"))
        XCTAssertFalse(text.contains("private-password"))
        XCTAssertFalse(text.contains("/Users/alice"))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertTrue(text.contains("[private path]"))
        XCTAssertTrue(text.contains(id.uuidString))
        XCTAssertTrue(text.contains("provider\\nforged"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testFailedWritesRemainVisibleAndRetryPreservesPendingEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        try Data("block directory".utf8).write(to: store.directory)
        store.record(level: .error, category: "test", message: "failed entry")
        await store.flush()
        XCTAssertNotNil(store.errorMessage)
        try FileManager.default.removeItem(at: store.directory)
        store.retry()
        await store.flush()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(try fixture.text().contains("failed entry"))
    }

    func testFlushIncludesRecordsEnqueuedWhileWaiting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.record(level: .info, category: "test", message: "initial record")
        let incoming = Task { @MainActor in
            for index in 0..<20 {
                store.record(level: .info, category: "test", message: "incoming-\(index)")
            }
        }
        await store.flush()
        XCTAssertTrue(try fixture.text().contains("incoming-19"))
        await incoming.value
    }

    func testSpecialLogTargetsRefusePromptlyWithoutFollowingLinksAndRetryRetainsEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = fixture.root.appending(path: "log-boundary-probe")
        let main = fixture.root.appending(path: "main.swift")
        let program = #"""
        import Darwin
        import Foundation

        @main struct LogBoundaryProbe {
            @MainActor static func main() async throws {
                let root = URL(filePath: CommandLine.arguments[1])
                let mode = CommandLine.arguments[2]
                let directory = root.appending(path: "logs")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appending(path: "cellar-2023-11-14.log")
                let external = root.appending(path: "outside.txt")
                let original = Data("outside remains unchanged".utf8)
                try original.write(to: external)
                var reader: Int32 = -1
                if mode.hasPrefix("fifo") {
                    guard mkfifo(target.path, 0o600) == 0 else { exit(2) }
                    if mode == "fifo-reader" {
                        reader = open(target.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                        guard reader >= 0 else { exit(3) }
                    }
                } else if mode == "directory" {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                } else {
                    let destination = mode == "dangling-symlink" ? root.appending(path: "absent.txt") : external
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
                }
                defer { if reader >= 0 { close(reader) } }
                let suite = "CellarLogBoundary-\(UUID())"
                guard let defaults = UserDefaults(suiteName: suite) else { exit(6) }
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = FileLogStore(directory: directory, defaults: defaults,
                                         now: { Date(timeIntervalSince1970: 1_700_000_000) })
                store.record(level: .error, category: "test", message: "entry retained after refusal")
                await store.flush()
                guard store.errorMessage != nil, try Data(contentsOf: external) == original,
                      !FileManager.default.fileExists(atPath: root.appending(path: "absent.txt").path) else { exit(4) }
                try FileManager.default.removeItem(at: target)
                store.retry()
                await store.flush()
                guard store.errorMessage == nil,
                      try String(contentsOf: target, encoding: .utf8).contains("entry retained after refusal") else { exit(5) }
            }
        }
        """#
        try Data(program.utf8).write(to: main)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let environment = ShellEnvironmentResolver(homeDirectory: fixture.root, temporaryDirectory: fixture.root).environment()
        let runner = ProcessRunner()
        let compile = try await runner.run(ProcessRequest(executableURL: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-parse-as-library", root.appending(path: "Services/FileLogStore.swift").path,
                        root.appending(path: "Models/DiagnosticText.swift").path, main.path,
                        "-target", "arm64-apple-macos26.0", "-o", executable.path],
            environment: environment, currentDirectoryURL: fixture.root, timeout: .seconds(60)))
        XCTAssertEqual(compile.terminationStatus, 0, compile.errorText)
        for mode in ["fifo", "fifo-reader", "symlink", "dangling-symlink", "directory"] {
            let probeRoot = fixture.root.appending(path: mode)
            let result = try await runner.run(ProcessRequest(executableURL: executable, arguments: [probeRoot.path, mode],
                environment: environment, currentDirectoryURL: fixture.root, timeout: .seconds(2)))
            XCTAssertEqual(result.terminationStatus, 0, "\(mode): \(result.errorText)")
        }
    }

    func testNewLogFileIsPrivateAndExistingContentIsAppended() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.record(level: .info, category: "test", message: "first entry")
        await store.flush()
        store.record(level: .error, category: "test", message: "second entry")
        await store.flush()
        let file = try XCTUnwrap(fixture.logFiles().first)
        var metadata = stat()
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        let text = try fixture.text()
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.contains("first entry"))
        XCTAssertTrue(text.contains("second entry"))
        XCTAssertNil(store.errorMessage)
    }

    private final class Clock {
        var date: Date
        init(date: Date) { self.date = date }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        var directory: URL { root.appendingPathComponent("logs", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CellarFileLogs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suite = "CellarFileLogTests-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }

        func store(maximumFileBytes: Int = 10 * 1024 * 1024, maximumTotalBytes: Int = 50 * 1024 * 1024,
                   now: @escaping @MainActor () -> Date = Date.init) -> FileLogStore {
            FileLogStore(directory: directory, defaults: defaults, maximumFileBytes: maximumFileBytes,
                         maximumTotalBytes: maximumTotalBytes, now: now)
        }

        func logFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        func text() throws -> String {
            try logFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
