import XCTest
@testable import Cellar

final class ExecutableLocatorTests: XCTestCase {
    func testFindsExecutableInPathOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CellarExecutableLocatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = root.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = second.appending(path: "tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = ExecutableLocator().locate("tool", path: "\(first.path):\(second.path)")
        XCTAssertEqual(result?.path, executable.path)
    }

    func testRejectsNamesContainingAPathSeparator() {
        XCTAssertNil(ExecutableLocator().locate("../tool", path: "/usr/bin"))
    }
}
