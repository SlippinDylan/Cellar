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

    func testPreferredInstalledVersionOverridesDefaultForControlledSession() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "CellarNodeResolverTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        let nvm = home.appending(path: ".nvm", directoryHint: .isDirectory)
        let alias = nvm.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0\n".utf8).write(to: alias.appending(path: "default"))
        for version in ["v20.0.0", "v22.0.0"] {
            let bin = nvm.appending(path: "versions/node/\(version)/bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let node = bin.appending(path: "node")
            XCTAssertTrue(FileManager.default.createFile(atPath: node.path, contents: Data()))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        }

        let resolver = NodeEnvironmentResolver(homeDirectory: home)
        let environment = resolver.environment(preferredNodeVersion: "v22.0.0")
        let installations = resolver.installations(preferredNodeVersion: "v22.0.0")

        let firstSearchPath = try XCTUnwrap(environment["PATH"]?.split(separator: ":").first)
        XCTAssertEqual(
            URL(filePath: String(firstSearchPath)).resolvingSymlinksInPath().path,
            nvm.appending(path: "versions/node/v22.0.0/bin").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(installations.first(where: { $0.isActive })?.version, "v22.0.0")
        XCTAssertEqual(installations.first(where: { $0.isDefault })?.version, "v20.0.0")
    }
}
