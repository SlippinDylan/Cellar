import XCTest
@testable import Cellar

final class NodeEnvironmentResolverTests: XCTestCase {
    func testResolvesConcreteDefaultAlias() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeResolverTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        let nvm = home.appending(path: ".nvm", directoryHint: .isDirectory)
        let alias = nvm.appending(path: "alias", directoryHint: .isDirectory)
        let bin = nvm.appending(path: "versions/node/v22.14.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("v22.14.0\n".utf8).write(to: alias.appending(path: "default"))
        let node = bin.appending(path: "node")
        XCTAssertTrue(FileManager.default.createFile(atPath: node.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let resolved = NodeEnvironmentResolver(homeDirectory: home).resolvedDefaultNodeBin(in: nvm)
        XCTAssertEqual(
            resolved?.resolvingSymlinksInPath().path,
            bin.resolvingSymlinksInPath().path
        )
    }

    func testSemanticVersionOrdering() throws {
        let older = try XCTUnwrap(SemanticVersion("v20.12.2"))
        let newer = try XCTUnwrap(SemanticVersion("v22.1.0"))
        XCTAssertLessThan(older, newer)
        XCTAssertTrue(newer.matches("22"))
        XCTAssertFalse(older.matches("22"))
    }

    func testDoesNotGuessWhenDefaultAliasIsMissing() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeResolverTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        let nvm = home.appending(path: ".nvm", directoryHint: .isDirectory)
        let bin = nvm.appending(path: "versions/node/v99.0.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appending(path: "node")
        XCTAssertTrue(FileManager.default.createFile(atPath: node.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        XCTAssertNil(NodeEnvironmentResolver(homeDirectory: home).resolvedDefaultNodeBin(in: nvm))
    }
}
