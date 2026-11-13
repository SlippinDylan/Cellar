import Darwin
import XCTest
@testable import Cellar

final class CaskInstalledMetadataTests: XCTestCase {
    func testLegacyReceiptVersionMustMatchInstalledDirectory() throws {
        for suffix in ["json", "internal.json", "rb"] {
            let fixture = try InstalledMetadataFixture()
            defer { fixture.remove() }
            if suffix == "rb" {
                try fixture.snapshot(raw: "raise 'never evaluate'", suffix: suffix)
            } else {
                try fixture.snapshot(json: ["token": "sample", "version": "4.0"], suffix: suffix)
            }
            try fixture.receipt(version: "2.0")
            XCTAssertThrowsError(try fixture.read(), suffix)
        }
    }

    func testLegacyFullJSONUsesReceiptInsteadOfRawPlaceholdersAndPlatformDefaults() throws {
        for suffix in ["json", "internal.json"] {
            let fixture = try InstalledMetadataFixture()
            defer { fixture.remove() }
            let owned = fixture.home.appending(path: "Library/Application Support/Stored Product").path
            try fixture.receipt(artifacts: [["app": ["Installed.app"]], ["zap": [["trash": owned]]]])
            try fixture.snapshot(json: ["token": "sample", "tap": "acme/apps", "version": "2.0",
                "url": "https://example.test/old-api.dmg",
                "artifacts": [["app": ["Other Platform.app"]], ["zap": [["trash": "/$HOME/Library/Application Support/Stored Product"]]]],
                "variations": ["arm64_tahoe": ["version": "3.0", "artifacts": [["app": ["Installed.app"]]]]]], suffix: suffix)
            let metadata = try fixture.read()
            XCTAssertEqual(metadata.artifacts.first { $0.kind == "app" }?.application?.source, "Installed.app")
            XCTAssertEqual(metadata.artifacts.first { $0.category == .zap }?.values, [owned])
        }
    }

    func testLegacyFullJSONWithoutStructuredReceiptCannotUseRawArtifacts() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: ["url": "https://example.test/app.dmg", "artifacts": [["app": ["Raw.app"]]]])
        try fixture.write(["source": ["tap": "acme/apps", "version": "3.0"]], to: fixture.root.appending(path: "INSTALL_RECEIPT.json"))
        XCTAssertThrowsError(try fixture.read())
    }

    func testKnownOldTokenUsesItsOwnInstalledReceiptAndConfig() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: [:])
        let old = fixture.caskroom.appending(path: "old-sample")
        try FileManager.default.moveItem(at: fixture.root.deletingLastPathComponent(), to: old)
        let file = old.appending(path: ".metadata/3.0/20270101010101/Casks/sample.json")
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appending(path: "old-sample.json"))
        let object: [String: Any] = ["token": "sample", "full_token": "acme/apps/sample", "tap": "acme/apps",
            "old_tokens": ["old-sample"], "name": ["Sample"], "version": "4.0", "installed": "3.0", "outdated": false, "artifacts": []]
        let package = try JSONDecoder().decode(BrewCaskPayload.self, from: JSONSerialization.data(withJSONObject: object)).model
        let metadata = try CaskInstalledMetadata.read(package: package, caskroom: fixture.caskroom, budget: .init())
        XCTAssertEqual(metadata.artifacts.first { $0.kind == "app" }?.application?.source, "Installed.app")
        XCTAssertEqual(metadata.installedToken, "old-sample")
        XCTAssertEqual(package.oldTokens, ["old-sample"])
    }

    func testMultipleOrInvalidKnownInstallationsFailClosed() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: [:])
        let copy = fixture.caskroom.appending(path: "old-sample")
        try FileManager.default.copyItem(at: fixture.root.deletingLastPathComponent(), to: copy)
        let copiedFile = copy.appending(path: ".metadata/3.0/20270101010101/Casks/sample.json")
        try FileManager.default.moveItem(at: copiedFile, to: copiedFile.deletingLastPathComponent().appending(path: "old-sample.json"))
        let payload: [String: Any] = ["token": "sample", "full_token": "acme/apps/sample", "tap": "acme/apps",
            "old_tokens": ["old-sample"], "name": ["Sample"], "version": "4.0", "installed": "3.0", "outdated": false, "artifacts": []]
        var package = try JSONDecoder().decode(BrewCaskPayload.self, from: JSONSerialization.data(withJSONObject: payload)).model
        XCTAssertThrowsError(try CaskInstalledMetadata.read(package: package, caskroom: fixture.caskroom, budget: .init()))
        package.oldTokens = ["../outside"]
        XCTAssertThrowsError(try CaskInstalledMetadata.read(package: package, caskroom: fixture.caskroom, budget: .init()))
    }

    func testCompactInstalledArtifactsOverrideReceiptAndCurrentRecipe() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.receipt(artifacts: [["app": ["Receipt.app"]]])
        try fixture.snapshot(json: ["artifacts": [["app": ["Installed.app"]], ["zap": [["trash": ["~/Library/Application Support/Installed"]]]]]])
        let metadata = try fixture.read()
        XCTAssertEqual(metadata.artifacts.first { $0.kind == "app" }?.application?.source, "Installed.app")
        XCTAssertEqual(metadata.artifacts.first { $0.category == .zap }?.values, ["~/Library/Application Support/Installed"])
        XCTAssertFalse(metadata.artifacts.contains { $0.values.contains("Current Recipe.app") })
    }

    func testCompactWithoutArtifactsUsesStructuredReceipt() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: [:])
        let metadata = try fixture.read()
        XCTAssertEqual(metadata.artifacts.first { $0.kind == "app" }?.application?.source, "Installed.app")
    }

    func testInternalJSONAndLegacyRubyUseOnlyInstalledData() throws {
        for suffix in ["internal.json", "rb"] {
            let fixture = try InstalledMetadataFixture()
            defer { fixture.remove() }
            if suffix == "rb" {
                try fixture.snapshot(raw: "raise 'Ruby must never be evaluated'", suffix: suffix)
            } else {
                try fixture.snapshot(json: ["token": "sample", "tap": "acme/apps", "version": "3.0",
                                            "artifacts": [["app": ["Internal.app"]]]], suffix: suffix)
            }
            let metadata = try fixture.read()
            XCTAssertEqual(metadata.artifacts.first { $0.kind == "app" }?.application?.source, "Installed.app")
        }
    }

    func testLegacyRubyReceiptRetainsExactUninstallApplicationDeclarationWithoutPkgMarker() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(raw: "raise 'never evaluate installed Ruby'", suffix: "rb")
        try fixture.receipt(artifacts: [["uninstall": [["delete": "/Applications/Installed.app"]]],
                                      ["zap": [["trash": "~/Library/Application Support/Installed"]]]])
        let metadata = try fixture.read()
        XCTAssertFalse(metadata.artifacts.contains { $0.kind == "pkg" })
        XCTAssertEqual(metadata.artifacts.first { $0.kind == "uninstall" }?.uninstallDeletePaths, ["/Applications/Installed.app"])
        XCTAssertEqual(metadata.artifacts.first { $0.category == .zap }?.values, ["~/Library/Application Support/Installed"])
    }

    func testLatestTimestampWinsAcrossVersionsThenJSONExtensionWins() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: ["artifacts": [["app": ["Old.app"]]]], version: "2.0", timestamp: "20260101010101")
        try fixture.snapshot(raw: "not evaluated", suffix: "rb")
        try fixture.snapshot(json: ["artifacts": [["app": ["Internal.app"]]]], suffix: "internal.json")
        try fixture.snapshot(json: ["artifacts": [["app": ["Selected.app"]]]])
        XCTAssertEqual(try fixture.read().artifacts.first { $0.kind == "app" }?.application?.source, "Selected.app")
        // A newer incomplete installation must not silently fall back to older working metadata.
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "3.0/20290101010101"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.read())
    }

    func testExplicitJSONVersionCanOverridePathButMustMatchInstalledVersionAndReceipt() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.receipt(version: "3.1")
        try fixture.snapshot(json: ["version": "3.1"])
        XCTAssertNoThrow(try fixture.read(), "The installed version comes from its directory; an explicit JSON version can differ")
        try fixture.snapshot(json: ["version": "4.0"])
        XCTAssertThrowsError(try fixture.read())
    }

    func testReceiptConfigAndSnapshotContentAndIdentityAreBoundIntoFingerprint() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: [:])
        let before = try fixture.read().fingerprint
        try fixture.write(["default": ["appdir": "/Custom Applications"]], to: fixture.root.appending(path: "config.json"))
        let configChanged = try fixture.read().fingerprint
        XCTAssertNotEqual(before, configChanged)
        try fixture.receipt(artifacts: [["app": ["Renamed.app"]]])
        let receiptChanged = try fixture.read().fingerprint
        XCTAssertNotEqual(configChanged, receiptChanged)
        try fixture.snapshot(json: ["artifacts": [["app": ["Different.app"]]]])
        XCTAssertNotEqual(receiptChanged, try fixture.read().fingerprint)
        let file = fixture.root.appending(path: "3.0/20270101010101/Casks/sample.json")
        let bytes = try Data(contentsOf: file)
        let previous = try fixture.read().fingerprint
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("old"))
        try bytes.write(to: file)
        XCTAssertNotEqual(previous, try fixture.read().fingerprint)
    }

    func testMissingCorruptAndConflictingInstalledRecordsFailClosed() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.read())
        try fixture.snapshot(json: [:])
        try fixture.receipt(version: "2.0")
        XCTAssertThrowsError(try fixture.read())
        try fixture.receipt(tap: "other/apps")
        XCTAssertThrowsError(try fixture.read())
        try fixture.receipt()
        try fixture.snapshot(json: ["token": "different"])
        XCTAssertThrowsError(try fixture.read())
        try fixture.snapshot(raw: "{broken")
        XCTAssertThrowsError(try fixture.read())
        try fixture.snapshot(json: [:])
        try Data("broken receipt".utf8).write(to: fixture.root.appending(path: "INSTALL_RECEIPT.json"))
        XCTAssertThrowsError(try fixture.read())
        try fixture.receipt()
        try Data("[]".utf8).write(to: fixture.root.appending(path: "config.json"))
        XCTAssertThrowsError(try fixture.read())
    }

    func testExplicitEmptyArtifactsAreDistinctFromMissingAndMalformedArtifacts() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: ["artifacts": []])
        XCTAssertTrue(try fixture.read().artifacts.isEmpty, "An explicit empty installed list must not borrow receipt or current artifacts")
        try fixture.snapshot(json: ["artifacts": [[String: Any]()]])
        XCTAssertThrowsError(try fixture.read())
        try fixture.snapshot(json: ["artifacts": "invalid"])
        XCTAssertThrowsError(try fixture.read())
    }

    func testLegacyRubyWithoutStructuredReceiptArtifactsCannotUseCurrentRecipe() throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(raw: "cask 'sample' do; app 'Ruby.app'; end", suffix: "rb")
        try fixture.write(["source": ["version": "3.0", "tap": "acme/apps"]], to: fixture.root.appending(path: "INSTALL_RECEIPT.json"))
        XCTAssertThrowsError(try fixture.read())
    }

    func testSymlinkSnapshotReceiptAndAncestorAreRejected() throws {
        for component in ["snapshot", "receipt", "ancestor"] {
            let fixture = try InstalledMetadataFixture()
            defer { fixture.remove() }
            try fixture.snapshot(json: [:])
            let path: URL
            switch component {
            case "snapshot": path = fixture.root.appending(path: "3.0/20270101010101/Casks/sample.json")
            case "receipt": path = fixture.root.appending(path: "INSTALL_RECEIPT.json")
            default: path = fixture.root.appending(path: "3.0")
            }
            let moved = path.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: path, to: moved)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
            XCTAssertThrowsError(try fixture.read(), component)
        }
    }

    func testBudgetLimitsAndCancellationPropagate() async throws {
        let fixture = try InstalledMetadataFixture()
        defer { fixture.remove() }
        try fixture.snapshot(json: [:])
        XCTAssertThrowsError(try fixture.read(budget: .init(entries: 1)))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.read()
        }
        do { _ = try await task.value; XCTFail("Cancelled installed metadata read must throw") }
        catch is CancellationError { }
    }
}

private struct InstalledMetadataFixture: Sendable {
    let home: URL
    var caskroom: URL { home.appending(path: "Caskroom") }
    var root: URL { caskroom.appending(path: "sample/.metadata") }

    init() throws {
        home = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarInstalledMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try receipt()
        try write(["default": ["appdir": "/Applications"]], to: root.appending(path: "config.json"))
    }

    func receipt(version: String = "3.0", tap: String = "acme/apps", artifacts: [[String: Any]] = [["app": ["Installed.app"]]]) throws {
        try write(["source": ["version": version, "tap": tap], "uninstall_artifacts": artifacts], to: root.appending(path: "INSTALL_RECEIPT.json"))
    }

    func snapshot(json: [String: Any], suffix: String = "json", version: String = "3.0", timestamp: String = "20270101010101") throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try snapshot(data: data, suffix: suffix, version: version, timestamp: timestamp)
    }

    func snapshot(raw: String, suffix: String = "json") throws {
        try snapshot(data: Data(raw.utf8), suffix: suffix, version: "3.0", timestamp: "20270101010101")
    }

    private func snapshot(data: Data, suffix: String, version: String, timestamp: String) throws {
        let file = root.appending(path: "\(version)/\(timestamp)/Casks/sample.\(suffix)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    func read(budget: CaskRemovalScanBudget = .init()) throws -> CaskInstalledMetadata {
        let package = HomebrewPackage(identity: .init(name: "acme/apps/sample", kind: .cask), displayName: "Sample",
            description: nil, homepage: nil, installedVersions: ["3.0"], currentVersion: "4.0", tap: "acme/apps",
            dependencies: [], pinned: false, deprecated: false, disabled: false,
            artifacts: [.init(kind: "app", values: ["Current Recipe.app"], category: .installed)])
        return try CaskInstalledMetadata.read(package: package, caskroom: caskroom, budget: budget)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}
