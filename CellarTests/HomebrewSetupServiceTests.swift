import Foundation
import XCTest
@testable import Cellar

final class HomebrewSetupServiceTests: XCTestCase {
    func testEveryFailedVerificationPreventsOpeningInstaller() async throws {
        for failure in [HomebrewSetupFailure.digestMismatch, .packageSignature, .gatekeeper] {
            let events = SetupEvents()
            let root = FileManager.default.temporaryDirectory.appending(path: "cellar-setup-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let service = HomebrewSetupService(
                temporaryRoot: root,
                metadata: { try Self.metadata() },
                download: { _, destination in try Data("fixture".utf8).write(to: destination) },
                digest: { _ in failure == .digestMismatch ? String(repeating: "b", count: 64) : String(repeating: "a", count: 64) },
                packageSignature: { _ in await events.record("signature"); if failure == .packageSignature { throw failure } },
                gatekeeper: { _ in await events.record("gatekeeper"); if failure == .gatekeeper { throw failure } },
                opener: { _ in await events.record("open") }
            )
            do {
                _ = try await service.openInstaller()
                XCTFail("Expected verification failure")
            } catch let error as HomebrewSetupError {
                XCTAssertEqual(error.failure, failure)
                XCTAssertEqual(error.officialURL, CatalogWebsites.homebrew)
            }
            let recorded = await events.values
            XCTAssertFalse(recorded.contains("open"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testSuccessfulChecksOpenInOrderAndRetainFileUntilCompletion() async throws {
        let events = SetupEvents()
        let root = FileManager.default.temporaryDirectory.appending(path: "cellar-setup-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = HomebrewSetupService(
            temporaryRoot: root,
            metadata: { await events.record("metadata"); return try Self.metadata() },
            download: { _, destination in await events.record("download"); try Data("fixture".utf8).write(to: destination) },
            digest: { _ in await events.record("digest"); return String(repeating: "a", count: 64) },
            packageSignature: { _ in await events.record("signature") },
            gatekeeper: { _ in await events.record("gatekeeper") },
            opener: { url in XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); await events.record("open") }
        )
        let package = try await service.openInstaller()
        let recorded = await events.values
        XCTAssertEqual(recorded, ["metadata", "download", "digest", "signature", "gatekeeper", "open"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        do { _ = try await service.openInstaller(); XCTFail("Expected retained handoff protection") }
        catch { XCTAssertEqual((error as? HomebrewSetupError)?.failure, .installationInProgress) }
        try await service.finishInstallerHandoff()
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }

    func testMissingInvalidMetadataAndDownloadFailureNeverReachTrustOrOpen() async throws {
        for failure in [HomebrewSetupFailure.digestMissing, .digestInvalid, .releaseMetadata, .download] {
            let events = SetupEvents()
            let root = FileManager.default.temporaryDirectory.appending(path: "cellar-setup-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let service = HomebrewSetupService(
                temporaryRoot: root,
                metadata: { if failure != .download { throw failure }; return try Self.metadata() },
                download: { _, destination in try Data("partial".utf8).write(to: destination); throw URLError(.timedOut) },
                digest: { _ in await events.record("digest"); return "" },
                packageSignature: { _ in await events.record("signature") },
                gatekeeper: { _ in await events.record("gatekeeper") },
                opener: { _ in await events.record("open") }
            )
            do { _ = try await service.openInstaller(); XCTFail("Expected failure") }
            catch {
                XCTAssertEqual((error as? HomebrewSetupError)?.failure, failure)
                XCTAssertEqual((error as? HomebrewSetupError)?.officialURL, CatalogWebsites.homebrew)
            }
            let recorded = await events.values
            XCTAssertTrue(recorded.isEmpty)
            if failure == .download { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), []) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)) }
        }
    }

    func testWrongSizeSymlinkAndCancelledDownloadsFailClosed() async throws {
        for mode in ["size", "symlink", "cancel"] {
            let events = SetupEvents()
            let root = FileManager.default.temporaryDirectory.appending(path: "cellar-setup-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let service = HomebrewSetupService(
                temporaryRoot: root,
                metadata: { try Self.metadata() },
                download: { _, destination in
                    if mode == "cancel" { throw CancellationError() }
                    if mode == "symlink" { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appending(path: "missing")) }
                    else { try Data("wrong length".utf8).write(to: destination) }
                },
                digest: { _ in await events.record("digest"); return String(repeating: "a", count: 64) },
                packageSignature: { _ in await events.record("signature") },
                gatekeeper: { _ in await events.record("gatekeeper") },
                opener: { _ in await events.record("open") }
            )
            do { _ = try await service.openInstaller(); XCTFail("Expected failure") }
            catch {
                if mode == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? HomebrewSetupError)?.failure, .download) }
            }
            let recorded = await events.values
            XCTAssertTrue(recorded.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testSignatureAndGatekeeperRejectMissingInvalidOrTruncatedVerdicts() async throws {
        let package = URL(filePath: "/tmp/cellar-fixture/Homebrew.pkg")
        for result in [Self.processResult("Status: no signature"), Self.processResult(""), Self.processResult("Status: signed by a certificate trusted by Mac OS X", status: 1), Self.processResult("Status: signed by a certificate trusted by Mac OS X", truncated: true)] {
            let trust = HomebrewInstallerTrustClient(run: { _ in result })
            do { try await trust.validatePackageSignature(package); XCTFail("Expected signature rejection") }
            catch { XCTAssertEqual(error as? HomebrewSetupFailure, .packageSignature) }
        }
        for result in [Self.processResult(""), Self.processResult("", error: "\(package.path): rejected"), Self.processResult("", error: "\(package.path): accepted", status: 3), Self.processResult("", error: "\(package.path): accepted", truncated: true)] {
            let trust = HomebrewInstallerTrustClient(run: { _ in result })
            do { try await trust.assessGatekeeper(package); XCTFail("Expected Gatekeeper rejection") }
            catch { XCTAssertEqual(error as? HomebrewSetupFailure, .gatekeeper) }
        }
        let requests = SetupRequests()
        let trust = HomebrewInstallerTrustClient(run: { request in
            await requests.record(request)
            return Self.processResult("   Status: signed by a certificate trusted by Mac OS X", error: "\(package.path): accepted\nsource=Notarized Developer ID")
        })
        try await trust.validatePackageSignature(package)
        try await trust.assessGatekeeper(package)
        let recorded = await requests.values
        XCTAssertEqual(recorded.map(\.executableURL.path), ["/usr/sbin/pkgutil", "/usr/sbin/spctl"])
        XCTAssertEqual(recorded[0].arguments, ["--check-signature", package.path])
        XCTAssertEqual(recorded[1].arguments, ["--assess", "--type", "install", "--verbose=2", "--ignore-cache", "--no-cache", package.path])
        XCTAssertEqual(recorded[0].timeout, .seconds(30))
        XCTAssertEqual(recorded[0].currentDirectoryURL, package.deletingLastPathComponent())
        XCTAssertNil(recorded[0].environment["HOME"])
    }

    func testCLTOnlyUsesControlledDetectionAndSystemRequest() async throws {
        let requests = SetupRequests()
        let directory = URL(filePath: "/tmp/cellar-clt-fixture")
        let service = CommandLineToolsService(workingDirectory: directory, run: { request in
            await requests.record(request)
            return Self.processResult(request.arguments == ["--print-path"] ? "/Library/Developer/CommandLineTools\n" : "install requested")
        })
        let state = try await service.state()
        XCTAssertEqual(state, .installed(developerDirectory: "/Library/Developer/CommandLineTools"))
        try await service.requestInstallation()
        let recorded = await requests.values
        XCTAssertEqual(recorded.map(\.arguments), [["--print-path"], ["--install"]])
        XCTAssertTrue(recorded.allSatisfy { $0.executableURL.path == "/usr/bin/xcode-select" && $0.currentDirectoryURL == directory && $0.timeout == .seconds(15) })
        let missing = CommandLineToolsService(workingDirectory: directory, run: { _ in Self.processResult("", status: 2) })
        let missingState = try await missing.state()
        XCTAssertEqual(missingState, .notInstalled)
        do { try await missing.requestInstallation(); XCTFail("Expected failed request") }
        catch { XCTAssertTrue(error is CommandLineToolsError) }
    }

    func testSHA256ReadsOnlyTemporaryFixture() async throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "cellar-sha256-test-\(UUID())")
        try Data("abc".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let digest = try await HomebrewSetupService.sha256(of: fixture)
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCleanupFailureStillReportsOfficialRecoveryURL() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cellar-setup-test-\(UUID())")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let service = HomebrewSetupService(
            temporaryRoot: root,
            metadata: { try Self.metadata() },
            download: { _, destination in
                try Data("fixture".utf8).write(to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
                throw HomebrewSetupFailure.download
            },
            digest: { _ in XCTFail("Must stop before digest"); return "" },
            packageSignature: { _ in XCTFail("Must stop before signature") },
            gatekeeper: { _ in XCTFail("Must stop before Gatekeeper") },
            opener: { _ in XCTFail("Must never open") }
        )
        do { _ = try await service.openInstaller(); XCTFail("Expected cleanup failure") }
        catch {
            XCTAssertEqual((error as? HomebrewSetupError)?.failure, .temporaryFile)
            XCTAssertEqual((error as? HomebrewSetupError)?.officialURL, CatalogWebsites.homebrew)
        }
    }

    private static func processResult(_ output: String, error: String = "", status: Int32 = 0, truncated: Bool = false) -> ProcessResult {
        ProcessResult(standardOutput: Data(output.utf8), standardError: Data(error.utf8), terminationStatus: status, standardOutputWasTruncated: truncated, standardErrorWasTruncated: truncated)
    }

    private static func metadata() throws -> HomebrewInstallerMetadata {
        try HomebrewInstallerMetadata(version: "1.2.3", downloadURL: CatalogWebsites.url(host: "github.com", path: "/Homebrew/brew/releases/download/1.2.3/Homebrew.pkg"), sha256: String(repeating: "a", count: 64), size: 7)
    }
}

actor SetupEvents {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private actor SetupRequests {
    private(set) var values: [ProcessRequest] = []
    func record(_ value: ProcessRequest) { values.append(value) }
}
