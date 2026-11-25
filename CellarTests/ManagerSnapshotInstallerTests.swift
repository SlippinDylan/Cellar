import XCTest
@testable import Cellar

final class ManagerSnapshotInstallerTests: XCTestCase {
    func testBundledNodeSnapshotExactlyMatchesCheckedInProductionWhitelist() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appending(path: "Resources/Managers")
        let manifest = try String(contentsOf: repository.appending(path: "scripts/node-manager/app-bundle-manifest.txt"), encoding: .utf8)
        let paths = manifest.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(paths.count, 25)
        let managers = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Managers")
        let node = managers.appending(path: "node-manager")
        var bundledFiles = Set<String>()
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: managers, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        for case let entry as URL in entries {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertNotEqual(values.isSymbolicLink, true)
            XCTAssertFalse(entry.pathComponents.contains(".runtime"))
            XCTAssertNotEqual(entry.pathExtension, "log")
            XCTAssertFalse(entry.lastPathComponent.contains("test"))
            if values.isRegularFile == true, entry.path.hasPrefix(node.path + "/") {
                bundledFiles.insert(String(entry.path.dropFirst(node.path.count + 1)))
            }
        }
        XCTAssertEqual(bundledFiles, Set(paths))
        for path in paths {
            XCTAssertEqual(try Data(contentsOf: node.appending(path: path)), try Data(contentsOf: source.appending(path: "node-manager/\(path)")), path)
        }
        XCTAssertEqual(try Data(contentsOf: managers.appending(path: "SNAPSHOT.md")),
                       try Data(contentsOf: source.appending(path: "SNAPSHOT.md")))
    }

    func testInstallsCompleteSnapshotIntoApplicationSupportRoot() async throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "CellarSnapshotInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }

        let old = support.appending(path: "Cellar/Managers/previous-snapshot")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let oldMarker = old.appending(path: "previous-runtime")
        try Data("preserved".utf8).write(to: oldMarker)
        let installer = ManagerSnapshotInstaller(
            bundle: Bundle.main,
            applicationSupportDirectory: support
        )
        let status = try await installer.installIfNeeded()

        XCTAssertEqual(status.version, ManagerSnapshotInstaller.snapshotVersion)
        XCTAssertTrue(status.nodeAvailable)
        XCTAssertTrue(status.homebrewAvailable)
        XCTAssertTrue(status.shellAvailable)
        let installed = support.appending(path: "Cellar/Managers/\(ManagerSnapshotInstaller.snapshotVersion)")
        XCTAssertEqual(status.location, installed.path)
        XCTAssertNotEqual(ManagerSnapshotInstaller.snapshotVersion, "previous-snapshot")
        XCTAssertEqual(try String(contentsOf: oldMarker, encoding: .utf8), "preserved")
        let bundled = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Managers/node-manager/lib/json_execute.sh")
        XCTAssertEqual(try Data(contentsOf: installed.appending(path: "node-manager/lib/json_execute.sh")), try Data(contentsOf: bundled))
        let reused = try await installer.installIfNeeded()
        XCTAssertEqual(reused.location, installed.path)

        try FileManager.default.removeItem(at: installed.appending(path: "node-manager/main.sh"))
        let repaired = try await installer.installIfNeeded()
        XCTAssertEqual(repaired.location, installed.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appending(path: "node-manager/main.sh").path))

        try FileManager.default.removeItem(at: installed)
        let reinstalled = try await installer.installIfNeeded()
        XCTAssertEqual(reinstalled.location, installed.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appending(path: "node-manager/lib/json_execute.sh").path))
    }
}
