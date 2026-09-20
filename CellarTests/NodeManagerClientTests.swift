import XCTest
@testable import Cellar

final class NodeManagerClientTests: XCTestCase {
    func testKeepsCoreNodeDataWhenOutdatedCheckFails() async throws {
        let manager = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeManagerClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manager) }

        let script = manager.appending(path: "main.sh")
        let contents = #"""
        #!/bin/bash
        case "$2" in
          summary)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"/test/node","npmPath":"/test/npm","nodeVersion":"v24.0.0","npmVersion":"11.0.0","nvmLoaded":false,"globalPrefix":"/test","globalRoot":"/test/lib/node_modules","registry":"https://registry.npmjs.org/"}}'
            ;;
          packages)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{"example":{"version":"1.0.0"}}}}'
            ;;
          config)
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"config","data":{"registry":"https://registry.npmjs.org/","cache":"/test/cache","prefix":"/test","userRegistry":"","projectRegistry":"","globalRegistry":""}}'
            ;;
          outdated)
            printf '%s\n' '{"ok":false,"schemaVersion":1,"command":"outdated","error":{"code":"npm-outdated-failed","stderr":"offline"}}'
            exit 1
            ;;
          *) exit 2 ;;
        esac
        """#
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = NodeManagerClient(runner: ProcessRunner())
        let snapshot = try await client.loadSnapshot(managerDirectory: manager)

        XCTAssertEqual(snapshot.summary.nodeVersion, "v24.0.0")
        XCTAssertEqual(snapshot.configuration.prefix, "/test")
        XCTAssertEqual(snapshot.packages.count, 1)
        XCTAssertEqual(snapshot.packages.first?.name, "example")
        XCTAssertNotNil(snapshot.outdatedError)
    }
}
