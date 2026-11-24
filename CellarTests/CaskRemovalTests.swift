import Darwin
import XCTest
@testable import Cellar

final class CaskRemovalTests: XCTestCase {
    func testFingerprintBudgetCannotDropProtectedDescendantsFromAncestorProtection() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let child = try fixture.file("Library/Application Support/Sample/Acme/data").deletingLastPathComponent()
        let parent = child.deletingLastPathComponent()
        let package = fixture.package(extraArtifacts: [
            .init(kind: "trash", values: ["~/Library/Application Support/Sample/Acme"], category: .zap)
        ])
        // This boundary admits the parent fingerprint but exhausts discovery before the protected child.
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps], maximumScanEntries: 27)
        let plan = try scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertTrue(plan.warnings.contains(.incompleteScan))
        XCTAssertEqual(try XCTUnwrap(plan.entries.first { $0.path == parent.path }).disposition, .protected)
        XCTAssertFalse(plan.entries.contains { $0.disposition == .remove && CaskRemovalPathPolicy.overlaps($0.path, child.path) })
    }

    func testProtectedDescendantsProtectCaseAndUnicodeAliasesOfTheirAncestors() throws {
        for (name, alias) in [("Sample", "sample"), ("Samplé", "sample\u{301}")] {
            let fixture = try RemovalFixture()
            defer { fixture.remove() }
            _ = try fixture.app(name, bundle: "com.acme.sample")
            let child = try fixture.file("Library/Application Support/\(name)/Acme/data").deletingLastPathComponent()
            let parent = child.deletingLastPathComponent()
            let package = fixture.package(name: name, extraArtifacts: [
                .init(kind: "trash", values: ["~/Library/Application Support/\(alias)/Acme"], category: .zap)
            ])
            let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
            XCTAssertEqual(try XCTUnwrap(plan.entries.first { $0.path == parent.path }).disposition, .protected, name)
            XCTAssertFalse(plan.entries.contains { $0.disposition == .remove && CaskRemovalPathPolicy.overlaps($0.path, child.path) }, name)
        }
    }

    func testFirmlinkTargetAliasIsNotCountedAsASharedApplicationCopy() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let alias = URL(filePath: "/System/Volumes/Data" + app.path)
        XCTAssertEqual(try CaskRemovalFileSystem.fingerprint(app.path), try CaskRemovalFileSystem.fingerprint(alias.path))
        let package = fixture.package(installedArtifacts: [
            .init(kind: "app", values: ["Sample.app"], category: .installed,
                  application: .init(source: "Sample.app", target: alias.path))
        ])
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "NoCache"), otherCasks: [])
        XCTAssertFalse(plan.warnings.contains(.sharedData))
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .remove)
        _ = try fixture.app("Actual Copy", bundle: "com.acme.sample")
        let shared = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "NoCache"), otherCasks: [])
        XCTAssertTrue(shared.warnings.contains(.sharedData))
        XCTAssertEqual(shared.entries.first { $0.path == preferences.path }?.disposition, .protected)
    }

    func testVerificationSessionDoesNotExhaustSharedBudgetAndStillDetectsNewOwners() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let target = try fixture.app("Sample", bundle: "com.acme.sample")
        for index in 0..<200 { _ = try fixture.app("Other \(index)", bundle: "com.other.app\(index)") }
        let plan = try fixture.scan()
        try FileManager.default.removeItem(at: target)
        let session = try fixture.scanner.makeVerificationSession(plan)
        for _ in 0..<30 { XCTAssertTrue(try session.sharedDataRemainsProtected()) }
        _ = try fixture.app("New Owner", bundle: "com.acme.sample")
        XCTAssertFalse(try session.sharedDataRemainsProtected(), "A session must still discover new owners")
    }

    func testVerificationSessionInvalidatesChangedMetadataInsteadOfBlindlyReusingIt() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let target = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("Other", bundle: "com.other.app")
        let plan = try fixture.scan()
        try FileManager.default.removeItem(at: target)
        let session = try fixture.scanner.makeVerificationSession(plan)
        XCTAssertTrue(try session.sharedDataRemainsProtected())
        _ = try fixture.app("Other", bundle: "com.acme.sample")
        XCTAssertFalse(try session.sharedDataRemainsProtected())
    }

    func testExactZapPathsIncludeCodeAndNestedChromeButNeverRemoveVendorParent() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Visual Studio Code", bundle: "com.microsoft.VSCode")
        let code = try fixture.file("Library/Application Support/Code/settings.json").deletingLastPathComponent()
        let cask = fixture.package(name: "Visual Studio Code", extraArtifacts: [
            .init(kind: "trash", values: ["~/Library/Application Support/Code"], category: .zap)
        ])
        let codePlan = try fixture.scanner.scan(package: cask, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(codePlan.entries.first { $0.path == code.path }?.disposition, .remove)
        _ = try fixture.app("Google Chrome", bundle: "com.google.Chrome")
        let chrome = try fixture.file("Library/Application Support/Google/Chrome/profile").deletingLastPathComponent()
        let vendor = chrome.deletingLastPathComponent()
        let chromeCask = fixture.package(name: "Google Chrome", extraArtifacts: [
            .init(kind: "trash", values: ["~/Library/Application Support/Google", "~/Library/Application Support/Google/Chrome"], category: .zap)
        ])
        let chromePlan = try fixture.scanner.scan(package: chromeCask, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(chromePlan.entries.first { $0.path == chrome.path }?.disposition, .remove)
        XCTAssertEqual(chromePlan.entries.first { $0.path == vendor.path }?.disposition, .protected)
        XCTAssertTrue(CaskRemovalAuthorizationRequest.allows(chrome.path, home: fixture.home.path))
    }

    func testOtherCaskExactOrParentClaimsKeepSharedZapData() throws {
        for otherClaim in ["~/Library/Application Support/Code", "~/Library/Application Support/Code/Shared"] {
            let fixture = try RemovalFixture()
            defer { fixture.remove() }
            _ = try fixture.app("Sample", bundle: "com.acme.sample")
            _ = try fixture.app("Other", bundle: "com.other.app")
            let code = try fixture.file("Library/Application Support/Code/Shared/data").deletingLastPathComponent().deletingLastPathComponent()
            let target = fixture.package(extraArtifacts: [.init(kind: "trash", values: ["~/Library/Application Support/Code"], category: .zap)])
            let other = fixture.package(name: "Other", extraArtifacts: [.init(kind: "trash", values: [otherClaim], category: .zap)])
            let plan = try fixture.scanner.scan(package: target, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [other])
            XCTAssertEqual(plan.entries.first { $0.path == code.path }?.disposition, .protected)
        }
    }

    func testExactZapCannotExpandGlobsEscapeLibraryOrDeleteBroadRoots() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let values = ["~/Documents/Sample", "~/Library/Application Support", "~/Library/Caches/*", "~/Library/Caches/../Preferences",
                      "~/Library/Caches/Homebrew", "~/Library/Application Support/Acme"]
        _ = try fixture.file("Library/Application Support/Acme/other-product")
        let package = fixture.package(extraArtifacts: [.init(kind: "trash", values: values, category: .zap)])
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        let vendor = fixture.home.appending(path: "Library/Application Support/Acme").path
        XCTAssertEqual(plan.entries.first { $0.path == vendor }?.disposition, .protected)
        XCTAssertFalse(plan.entries.contains { $0.disposition == .remove && values.dropLast().contains("~/" + $0.path.dropFirst(fixture.home.path.count + 1)) })
        XCTAssertNil(CaskRemovalPathPolicy.relatedPath("~/Library/Caches/../Preferences", home: fixture.home))
        for name in ["Homebrew", "homebrew", "HOMEBREW", "HoMeBrEw"] {
            XCTAssertNil(CaskRemovalPathPolicy.relatedPath("~/Library/Caches/" + name, home: fixture.home))
            XCTAssertNil(CaskRemovalPathPolicy.relatedPath("~/Library/Caches/" + name + "/downloads/other.dmg", home: fixture.home))
        }
    }

    func testResolvedArtifactTargetOverridesNestedSourceAndOtherInstalledCopies() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let sourceCopy = try fixture.app("Source", bundle: "com.other.source")
        let installed = try fixture.app("Renamed", bundle: "com.acme.sample")
        let target = fixture.home.appending(path: "Custom Apps/Renamed.app")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: installed, to: target)
        let payload = try JSONSerialization.data(withJSONObject: ["app": ["Archive/Source.app"], "target": target.path])
        let artifacts = try JSONDecoder().decode(DynamicObject.self, from: payload).artifacts
        XCTAssertEqual(artifacts.count, 1, "target is an app location, not an independent artifact")
        XCTAssertEqual(artifacts[0].application?.source, "Archive/Source.app")
        XCTAssertEqual(artifacts[0].application?.target, target.path)
        let plan = try fixture.scanner.scan(package: fixture.package(installedArtifacts: artifacts),
            cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(plan.appURL, target)
        XCTAssertFalse(plan.entries.contains { $0.path == sourceCopy.path })
        XCTAssertEqual(plan.applicationIdentities, [.init(bundleURL: target, bundleIdentifier: "com.acme.sample")])
    }

    func testLegacyNestedSourceAndRelativeTargetUseSavedInstalledAppDirectory() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let staged = try fixture.app("Renamed", bundle: "com.acme.sample")
        let installed = fixture.home.appending(path: "Custom Apps/Renamed.app")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged, to: installed)
        let caskroom = fixture.home.appending(path: "Caskroom")
        let config = caskroom.appending(path: "sample/.metadata/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["default": ["appdir": "/Applications"],
            "env": ["appdir": fixture.apps.path], "explicit": ["appdir": installed.deletingLastPathComponent().path]]).write(to: config)
        let json = #"{"app":["Archive/Source.app",{"target":"Renamed.app"}]}"#
        let artifacts = try JSONDecoder().decode(DynamicObject.self, from: Data(json.utf8)).artifacts
        let plan = try fixture.scanner.scan(package: fixture.package(installedArtifacts: artifacts),
            cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [], caskroom: caskroom)
        XCTAssertEqual(plan.appURL, installed)
        XCTAssertFalse(plan.warnings.contains(.incompleteScan))
        let nested = try JSONDecoder().decode(DynamicObject.self, from: Data(#"{"app":["Archive/Renamed.app"]}"#.utf8)).artifacts
        let nestedPlan = try fixture.scanner.scan(package: fixture.package(installedArtifacts: nested),
            cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [], caskroom: caskroom)
        XCTAssertEqual(nestedPlan.appURL, installed)
    }

    func testPkgUninstallAppPathsSupplyIdentityAndMissingPathsStayIncomplete() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Meeting", bundle: "com.acme.meeting")
        let payload = try JSONSerialization.data(withJSONObject: ["uninstall": [["delete": [app.path], "pkgutil": "com.acme.pkg"]]])
        let uninstall = try JSONDecoder().decode(DynamicObject.self, from: payload).artifacts
        XCTAssertEqual(uninstall.first?.uninstallDeletePaths, [app.path])
        let pkg = HomebrewCaskArtifact(kind: "pkg", values: ["Installer.pkg"], category: .installed)
        let package = fixture.package(installedArtifacts: [pkg] + uninstall)
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(plan.appURL, app)
        let receiptPlan = try fixture.scanner.scan(package: fixture.package(installedArtifacts: uninstall),
            cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(receiptPlan.appURL, app, "Uninstall-only installed receipts omit the pkg marker")
        XCTAssertEqual(receiptPlan.applicationIdentities, [.init(bundleURL: app, bundleIdentifier: "com.acme.meeting")])
        XCTAssertEqual(plan.applicationIdentities.first?.bundleIdentifier, "com.acme.meeting")
        let unknown = try fixture.scanner.scan(package: fixture.package(installedArtifacts: [pkg]),
            cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertNil(unknown.appURL)
        XCTAssertTrue(unknown.warnings.contains(.incompleteScan))
    }

    func testCaseVariantsOfOtherCaskClaimsRemainProtected() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("Other", bundle: "com.other.app")
        let data = try fixture.file("Library/Application Support/Code/profile").deletingLastPathComponent()
        let target = fixture.package(extraArtifacts: [.init(kind: "trash", values: ["~/Library/Application Support/Code"], category: .zap)])
        let other = fixture.package(name: "Other", extraArtifacts: [.init(kind: "trash", values: ["~/Library/Application Support/code"], category: .zap)])
        let plan = try fixture.scanner.scan(package: target, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [other])
        XCTAssertEqual(plan.entries.first { $0.path == data.path }?.disposition, .protected)
        XCTAssertTrue(CaskRemovalPathPolicy.overlaps(data.path, fixture.home.appending(path: "Library/Application Support/code/Shared").path))
    }

    func testMissingConfigOrMalformedTargetNeverSelectsAnUnrelatedDefaultCopy() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.other.sample")
        let missingConfig = fixture.home.appending(path: "Caskroom")
        let plan = try fixture.scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"),
            otherCasks: [], caskroom: missingConfig)
        XCTAssertNil(plan.appURL)
        XCTAssertTrue(plan.warnings.contains(.incompleteScan))
        XCTAssertTrue(plan.applicationIdentities.isEmpty)
        let config = missingConfig.appending(path: "sample/.metadata/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: config)
        let damaged = try fixture.scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"),
            otherCasks: [], caskroom: missingConfig)
        XCTAssertTrue(damaged.applicationIdentities.isEmpty)
        XCTAssertNil(damaged.appURL)
        let payload = #"{"app":["Sample.app"],"target":42}"#
        let artifacts = try JSONDecoder().decode(DynamicObject.self, from: Data(payload.utf8)).artifacts
        let malformed = try fixture.scanner.scan(package: fixture.package(installedArtifacts: artifacts),
            cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertNil(malformed.appURL)
        XCTAssertTrue(malformed.warnings.contains(.incompleteScan))
    }

    func testSurvivingNonHomebrewAppProtectsExactZapNameAndSubdirectories() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("OtherApp", bundle: "com.independent.other")
        let data = try fixture.file("Library/Application Support/OtherApp/Shared/profile").deletingLastPathComponent()
        let package = fixture.package(extraArtifacts: [.init(kind: "trash", values: ["~/Library/Application Support/OtherApp/Shared"], category: .zap)])
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(plan.entries.first { $0.path == data.path }?.disposition, .protected)
        XCTAssertTrue(plan.warnings.contains(.sharedData))
    }

    func testUnknownInstalledCaskApplicationLocationKeepsDataProtected() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let target = try fixture.app("Sample", bundle: "com.acme.sample")
        let other = try fixture.app("Other", bundle: "com.acme.sample")
        let unknown = fixture.home.appending(path: "Unresolved Apps/Other.app")
        try FileManager.default.createDirectory(at: unknown.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: other, to: unknown)
        let data = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let caskroom = fixture.home.appending(path: "Caskroom")
        let config = caskroom.appending(path: "other/.metadata/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid-config".utf8).write(to: config)
        let package = fixture.package(installedArtifacts: [
            .init(kind: "app", values: ["Sample.app"], category: .installed, application: .init(source: "Sample.app", target: target.path))
        ])
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"),
            otherCasks: [fixture.package(name: "Other")], caskroom: caskroom)
        XCTAssertEqual(plan.entries.first { $0.path == data.path }?.disposition, .protected)
        XCTAssertTrue(plan.warnings.contains(.incompleteScan))
        let inventory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plan.ownershipFingerprint.utf8)) as? [String: Any])
        XCTAssertEqual(inventory["complete"] as? Bool, false)
        let verification = try fixture.scanner.makeVerificationSession(plan)
        XCTAssertThrowsError(try verification.sharedDataRemainsProtected()) { error in
            guard let error = error as? HomebrewClientError, case .scanIncomplete = error else {
                return XCTFail("Expected incomplete ownership verification, got \(error)")
            }
        }
    }

    func testOtherCaskGlobAndDeepClaimsOnlyProtectOverlappingExactCandidates() throws {
        for claim in ["~/Library/Application Support/Code*", "~/Library/Application Support/Code/*",
                      "~/Library/Application Support/Code/**/shared", "~/Library/Application Support/Code/{Stable,Beta}",
                      "~/Library/Application Support/Code/a/b/c/d/e/f/g/h/i/profile"] {
            let fixture = try RemovalFixture()
            defer { fixture.remove() }
            _ = try fixture.app("Sample", bundle: "com.acme.sample")
            _ = try fixture.app("Other", bundle: "com.other.app")
            let code = try fixture.file("Library/Application Support/Code/profile").deletingLastPathComponent()
            let unrelated = try fixture.file("Library/Application Support/Unrelated/profile").deletingLastPathComponent()
            let target = fixture.package(extraArtifacts: [.init(kind: "trash", values: [
                "~/Library/Application Support/Code", "~/Library/Application Support/Unrelated"
            ], category: .zap)])
            let other = fixture.package(name: "Other", extraArtifacts: [.init(kind: "trash", values: [claim], category: .zap)])
            let plan = try fixture.scanner.scan(package: target, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [other])
            XCTAssertEqual(plan.entries.first { $0.path == code.path }?.disposition, .protected, claim)
            XCTAssertEqual(plan.entries.first { $0.path == unrelated.path }?.disposition, .remove, claim)
        }
    }

    func testOtherCaskClaimsProtectInferredPathsAndTotalsDoNotDoubleCountAliases() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("Other", bundle: "com.other.app")
        let sample = try fixture.file("Library/Application Support/Sample/profile").deletingLastPathComponent()
        let other = fixture.package(name: "Other", extraArtifacts: [.init(kind: "trash", values: ["~/Library/Application Support/sample"], category: .zap)])
        let shared = try fixture.scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [other])
        XCTAssertEqual(shared.entries.first { $0.path == sample.path }?.disposition, .protected)
        let entry = CaskRemovalEntry(path: sample.path, category: .applicationData, estimatedBytes: 4096, disposition: .remove, fingerprint: "same-file-identity")
        let alias = CaskRemovalEntry(path: sample.path.lowercased(), category: .applicationData, estimatedBytes: 4096, disposition: .remove, fingerprint: "same-file-identity")
        let totals = CaskRemovalPlan(displayName: "Sample", appURL: nil, entries: [entry, alias], warnings: [], ownershipFingerprint: "")
        XCTAssertEqual(totals.removalBytes, 4096)
    }

    func testVerificationBudgetFailureIsIncompleteRatherThanAChangedOwner() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", bundle: "com.acme.sample")
        let plan = try fixture.scan()
        try FileManager.default.removeItem(at: app)
        let constrained = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps], maximumScanEntries: 1)
        let session = try constrained.makeVerificationSession(plan)
        XCTAssertThrowsError(try session.sharedDataRemainsProtected()) { error in
            guard let error = error as? HomebrewClientError, case .scanIncomplete = error else {
                return XCTFail("Expected an incomplete verification, got \(error)")
            }
        }
        let download = try fixture.file("Library/Caches/Homebrew/downloads/sample.dmg")
        let entry = CaskRemovalEntry(path: download.path, category: .homebrewCache, estimatedBytes: nil,
            disposition: .remove, fingerprint: try CaskRemovalFileSystem.fingerprint(download.path))
        XCTAssertThrowsError(try fixture.scanner.cacheOwnershipIsUnchanged(entry, plan: plan, budget: .init(entries: 0))) { error in
            guard let error = error as? HomebrewClientError, case .scanIncomplete = error else {
                return XCTFail("Expected an incomplete cache verification, got \(error)")
            }
        }
    }

    func testKeptSharedDataAndGroupContainersStillHaveMeasuredSizes() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("Sample Beta", bundle: "com.acme.sample")
        let data = try fixture.file("Library/Application Support/com.acme.sample/data")
        let group = try fixture.file("Library/Group Containers/group.com.acme.sample/data")
        let package = fixture.package(extraArtifacts: [.init(kind: "trash", values: ["~/Library/Group Containers/group.com.acme.sample"], category: .zap)])
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        for path in [data.deletingLastPathComponent().path, group.deletingLastPathComponent().path] {
            let entry = try XCTUnwrap(plan.entries.first { $0.path == path })
            XCTAssertEqual(entry.disposition, .protected)
            XCTAssertGreaterThan(try XCTUnwrap(entry.estimatedBytes), 0)
            XCTAssertNil(entry.sizeFailure)
        }
        XCTAssertEqual(plan.removalBytes, plan.applicationBytes, "Measured protected data must not enter removal totals")
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.path))
    }

    func testPermissionFailureReportsReasonWithoutChangingDeletionEligibility() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let file = try fixture.file("Library/Caches/com.acme.sample/private")
        let cache = file.deletingLastPathComponent()
        XCTAssertEqual(chmod(cache.path, 0), 0)
        defer { chmod(cache.path, 0o700) }
        let plan = try fixture.scan()
        let entry = try XCTUnwrap(plan.entries.first { $0.path == cache.path })
        XCTAssertEqual(entry.disposition, .remove, "Read permission does not decide path ownership")
        XCTAssertNil(entry.estimatedBytes)
        XCTAssertEqual(entry.sizeFailure, .permissionDenied)
        let roundtrip = try JSONDecoder().decode(CaskRemovalPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(roundtrip.entries.first { $0.path == cache.path }?.sizeFailure, .permissionDenied)
    }

    func testSizeBudgetCannotSuppressDiscoveredPathsOrChangeOwnership() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        for index in 0..<150 { _ = try fixture.file("Library/Caches/com.acme.sample/\(index)") }
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps], maximumScanEntries: 200)
        let plan = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        let cache = try XCTUnwrap(plan.entries.first { $0.path == fixture.home.appending(path: "Library/Caches/com.acme.sample").path })
        XCTAssertNil(cache.estimatedBytes)
        XCTAssertEqual(cache.sizeFailure, .limitReached)
        let entry = try XCTUnwrap(plan.entries.first { $0.path == preferences.path })
        XCTAssertEqual(entry.disposition, .remove)
        XCTAssertEqual(entry.sizeFailure, .limitReached)
    }

    func testEmptyProtectedDirectoryIsMeasuredAsZero() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("Sample Beta", bundle: "com.acme.sample")
        let cache = fixture.home.appending(path: "Library/Caches/com.acme.sample")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let entry = try XCTUnwrap(fixture.scan().entries.first { $0.path == cache.path })
        XCTAssertEqual(entry.disposition, .protected)
        XCTAssertEqual(entry.estimatedBytes, 0)
        XCTAssertNil(entry.sizeFailure)
    }

    func testApprovedSystemApplicationAliasDoesNotProtectUnrelatedData() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let source = try fixture.app("Browser", bundle: "com.apple.browser")
        let systemApps = fixture.home.appending(path: "System/Applications")
        try FileManager.default.createDirectory(at: systemApps, withIntermediateDirectories: true)
        let browser = systemApps.appending(path: "Browser.app")
        try FileManager.default.moveItem(at: source, to: browser)
        let alias = fixture.apps.appending(path: "Browser.app")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "../System/Applications/Browser.app")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps], systemApplicationRoots: [systemApps])
        let plan = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .remove)
        let inventory = try JSONSerialization.jsonObject(with: Data(plan.ownershipFingerprint.utf8)) as? [String: Any]
        XCTAssertEqual(inventory?["complete"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: browser.path))
    }

    func testRelatedApplicationAliasStillProtectsSharedData() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", bundle: "com.acme.sample")
        try FileManager.default.createSymbolicLink(at: fixture.apps.appending(path: "Sample Alias.app"), withDestinationURL: app)
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let plan = try fixture.scan()
        XCTAssertTrue(plan.warnings.contains(.sharedData))
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .protected)
    }

    func testUnknownAndBrokenApplicationAliasesKeepOwnershipUnknown() throws {
        for broken in [false, true] {
            let fixture = try RemovalFixture()
            defer { fixture.remove() }
            _ = try fixture.app("Sample", bundle: "com.acme.sample")
            let target = fixture.home.appending(path: broken ? "Missing.app" : "Unapproved/Browser.app")
            if !broken { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(at: fixture.apps.appending(path: "Browser.app"), withDestinationURL: target)
            let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
            let plan = try fixture.scan()
            XCTAssertTrue(plan.warnings.contains(.incompleteScan))
            XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .protected)
        }
    }

    func testScanIncludesOwnedDataAndConfirmedDownloadButNotDocumentsOrOtherCaches() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let cache = try fixture.file("Library/Caches/com.acme.sample/item")
        let download = try fixture.file("Library/Caches/Homebrew/downloads/sample.dmg")
        let alias = fixture.home.appending(path: "Library/Caches/Homebrew/sample--3.0.dmg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: download)
        let older = try fixture.file("Library/Caches/Homebrew/sample--2.0.dmg")
        let unrelated = try fixture.file("Library/Caches/Homebrew/other--1.dmg")
        let document = try fixture.file("Documents/Sample/project")
        let plan = try fixture.scan(confirmedCache: download)
        XCTAssertEqual(plan.appURL, app)
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .remove)
        XCTAssertEqual(plan.entries.first { $0.path == cache.deletingLastPathComponent().path }?.category, .cache)
        XCTAssertEqual(plan.entries.first { $0.path == download.path }?.disposition, .remove)
        XCTAssertEqual(plan.entries.first { $0.path == alias.path }?.disposition, .remove)
        XCTAssertEqual(plan.entries.first { $0.path == older.path }?.disposition, .protected)
        XCTAssertFalse(plan.entries.contains { $0.path == unrelated.path || $0.path == document.path })
        XCTAssertNotNil(plan.applicationBytes)
        XCTAssertNotNil(plan.removalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
    }

    func testSurvivingCopyProtectsDataAndPostflightRejectsReappearingApp() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Sample", bundle: "com.acme.sample")
        _ = try fixture.app("Sample Beta", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let plan = try fixture.scan()
        XCTAssertTrue(plan.warnings.contains(.sharedData))
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .protected)
        try FileManager.default.removeItem(at: app)
        XCTAssertTrue(try fixture.scanner.sharedDataRemainsProtected(plan))
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        XCTAssertFalse(try fixture.scanner.sharedDataRemainsProtected(plan))
    }

    func testNameVariantCannotDeleteAnotherProductsData() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Foo Bar", bundle: "com.first.foo")
        _ = try fixture.app("FooBar", bundle: "com.second.foo")
        let support = try fixture.file("Library/Application Support/FooBar/settings").deletingLastPathComponent()
        let plan = try fixture.scan(name: "Foo Bar")
        XCTAssertEqual(plan.entries.first { $0.path == support.path }?.disposition, .protected)
    }

    func testFormulaTokenCollisionAndNewDownloadOwnerPreventCacheRemoval() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let download = try fixture.file("Library/Caches/Homebrew/downloads/sample.dmg")
        let alias = fixture.home.appending(path: "Library/Caches/Homebrew/sample--3.0.dmg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: download)
        let other = fixture.package(name: "sample", kind: .formula)
        let protected = try fixture.scan(confirmedCache: download, others: [other])
        XCTAssertTrue(protected.entries.filter { $0.category == .homebrewCache }.allSatisfy { $0.disposition == .protected })
        let plan = try fixture.scan(confirmedCache: download)
        let entry = try XCTUnwrap(plan.entries.first { $0.path == download.path })
        XCTAssertTrue(try fixture.scanner.cacheOwnershipIsUnchanged(entry, plan: plan))
        try FileManager.default.createSymbolicLink(at: alias.deletingLastPathComponent().appending(path: "other--1.dmg"), withDestinationURL: download)
        XCTAssertFalse(try fixture.scanner.cacheOwnershipIsUnchanged(entry, plan: plan))
    }

    func testUnreadableMetadataProtectsDataAndFIFOReadDoesNotBlock() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let broken = fixture.apps.appending(path: "Unknown.app/Contents")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let fifo = broken.appending(path: "Info.plist")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try CaskRemovalFileSystem.readRegularFile(fifo.path, limit: 1_024))
        let plan = try fixture.scan()
        XCTAssertTrue(plan.warnings.contains(.incompleteScan))
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .protected)
    }

    func testUnlinkDoesNotFollowSymlinksAndRejectsChangedIdentityOrAncestor() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let outside = try fixture.file("Documents/keep.txt")
        let link = fixture.home.appending(path: "Library/Caches/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let entry = try fixture.entry(link)
        try CaskRemovalFileSystem.remove(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let target = try fixture.file("Library/Caches/target")
        let confirmed = try fixture.entry(target)
        try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("old"))
        try Data("replacement".utf8).write(to: target)
        XCTAssertThrowsError(try CaskRemovalFileSystem.remove(confirmed))
        let symlinkRoot = fixture.home.appending(path: "Alias")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertThrowsError(try CaskRemovalFileSystem.fingerprint(symlinkRoot.appending(path: "keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRecursiveRemovalHonorsCancellationAndKeepsProtectedLinkTargets() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let nested = try fixture.file("Library/Caches/Sample/nested/file")
        let target = nested.deletingLastPathComponent().deletingLastPathComponent()
        let outside = try fixture.file("Documents/keep.txt")
        try FileManager.default.createSymbolicLink(at: target.appending(path: "outside"), withDestinationURL: outside)
        let entry = try fixture.entry(target)
        XCTAssertThrowsError(try CaskRemovalFileSystem.remove(entry) { throw CancellationError() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        try CaskRemovalFileSystem.remove(entry)
        XCTAssertFalse(CaskRemovalFileSystem.exists(target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testReadableMountedVolumeWithoutAppRootsDoesNotProtectUnrelatedData() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let recovery = fixture.home.appending(path: "Volumes/Recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        // Arbitrary volume folders are outside application discovery; do not descend into them.
        _ = try fixture.file("Volumes/Recovery/OtherFolder/NotAnInstall.app/Contents/Info.plist")
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps],
            mountedVolumes: [.init(url: recovery, identity: try CaskRemovalFileSystem.localVolumeIdentity(recovery.path), isLocal: true)])
        let plan = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .remove)
        XCTAssertFalse(plan.warnings.contains(.incompleteScan))
    }

    func testActualMountedSiblingProtectsDataAndReappearingSiblingInvalidatesPostflight() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let selected = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let volume = fixture.home.appending(path: "Volumes/External")
        try FileManager.default.createDirectory(at: volume.appending(path: "Applications"), withIntermediateDirectories: true)
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps],
            mountedVolumes: [.init(url: volume, identity: try CaskRemovalFileSystem.localVolumeIdentity(volume.path), isLocal: true)])
        let before = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(before.entries.first { $0.path == preferences.path }?.disposition, .remove)
        let sibling = volume.appending(path: "Applications/Sample Beta.app/Contents")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
        try data.write(to: sibling.appending(path: "Info.plist"))
        let after = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(after.entries.first { $0.path == preferences.path }?.disposition, .protected)
        XCTAssertTrue(after.warnings.contains(.sharedData))
        try FileManager.default.moveItem(at: sibling.deletingLastPathComponent(), to: volume.appending(path: "Sample Beta.app"))
        let topLevel = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(topLevel.entries.first { $0.path == preferences.path }?.disposition, .protected)
        XCTAssertTrue(topLevel.warnings.contains(.sharedData))
        try FileManager.default.removeItem(at: selected)
        XCTAssertFalse(try scanner.sharedDataRemainsProtected(before))
    }

    func testNonlocalUnknownOrReplacedMountedVolumeKeepsData() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        let volume = fixture.home.appending(path: "Volumes/External")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let identity = try CaskRemovalFileSystem.localVolumeIdentity(volume.path)
        var wrong = statfs()
        wrong.f_fsid.val.0 = identity.first &+ 1
        wrong.f_fsid.val.1 = identity.second
        for mounted in [
            CaskRemovalVolume(url: volume, identity: identity, isLocal: false),
            CaskRemovalVolume(url: volume, identity: .init(wrong), isLocal: true),
            CaskRemovalVolume(url: volume.appending(path: "missing"), identity: identity, isLocal: true)
        ] {
            let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps], mountedVolumes: [mounted])
            let plan = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
            XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .protected)
            XCTAssertTrue(plan.warnings.contains(.incompleteScan))
        }
        try FileManager.default.createSymbolicLink(at: volume.appending(path: "Applications"), withDestinationURL: fixture.apps)
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps],
            mountedVolumes: [.init(url: volume, identity: identity, isLocal: true)])
        let plan = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertEqual(plan.entries.first { $0.path == preferences.path }?.disposition, .protected)
    }

    func testInventoryAndCachePressureExhaustSharedBudgetWithoutAuthorizingCleanup() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let preferences = try fixture.file("Library/Preferences/com.acme.sample.plist")
        for index in 0..<120 {
            _ = try fixture.file("Applications/Folder/entry-\(index)")
            _ = try fixture.file("Library/Caches/Homebrew/other--\(index).dmg")
        }
        let scanner = CaskRemovalScanner(home: fixture.home, applicationRoots: [fixture.apps], maximumScanEntries: 60)
        let plan = try scanner.scan(package: fixture.package(), cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertTrue(plan.warnings.contains(.incompleteScan))
        XCTAssertFalse(plan.entries.contains { $0.disposition == .remove })
        XCTAssertTrue(plan.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                      "Budget exhaustion must not invent uninspected candidate paths")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
    }

    func testCachePressureRemainsBoundedAndProtectsSharedDownload() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let download = try fixture.file("Library/Caches/Homebrew/downloads/sample.dmg")
        let cache = download.deletingLastPathComponent().deletingLastPathComponent()
        for index in 0..<160 {
            try FileManager.default.createSymbolicLink(at: cache.appending(path: "sample--\(index).dmg"), withDestinationURL: download)
        }
        try FileManager.default.createSymbolicLink(at: cache.appending(path: "other--1.dmg"), withDestinationURL: download)
        // This broken external alias must never cause a traversal of its target.
        try FileManager.default.createSymbolicLink(atPath: cache.appending(path: "sample--external.dmg").path,
                                                   withDestinationPath: "/Volumes/UnavailableServer/never-read.dmg")
        let plan = try fixture.scan(confirmedCache: download)
        XCTAssertEqual(plan.entries.first { $0.path == download.path }?.disposition, .protected)
        XCTAssertEqual(plan.entries.first { $0.path == cache.appending(path: "sample--external.dmg").path }?.disposition, .protected)
        XCTAssertFalse(try fixture.scanner.cacheOwnershipIsUnchanged(try XCTUnwrap(plan.entries.first { $0.path == download.path }), plan: plan))
    }

    func testSizingRejectsSymlinkAncestorsAndHonorsEntryAndDeadlineBudgets() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let file = try fixture.file("Documents/Folder/file")
        let alias = fixture.home.appending(path: "Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file.deletingLastPathComponent())
        XCTAssertNil(try CaskRemovalFileSystem.allocatedSize(alias.appending(path: "file").path))
        XCTAssertEqual(CaskRemovalFileSystem.lexicalURL("/private/var/cache/downloads/../downloads/file")?.path,
                       "/private/var/cache/downloads/file")
        XCTAssertNil(CaskRemovalFileSystem.lexicalURL("/../../outside"))
        XCTAssertEqual(try CaskRemovalFileSystem.allocatedSize(alias.path), 0)
        XCTAssertNil(try CaskRemovalFileSystem.allocatedSize(file.path, budget: .init(entries: 0)))
        XCTAssertNil(try CaskRemovalFileSystem.allocatedSize(file.path, budget: .init(duration: .zero)))
        var visited = 0
        XCTAssertThrowsError(try CaskRemovalFileSystem.walk(fixture.home.path, budget: .init(entries: 12)) { _, _ in
            visited += 1
            return true
        })
        XCTAssertLessThanOrEqual(visited, 12)
    }

    func testCancellationPropagatesThroughScanAndSizing() async throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let scan = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.scan()
        }
        do { _ = try await scan.value; XCTFail("Cancelled scan must throw") }
        catch is CancellationError { }
        let sizing = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CaskRemovalFileSystem.allocatedSize(fixture.apps.path)
        }
        do { _ = try await sizing.value; XCTFail("Cancelled sizing must throw") }
        catch is CancellationError { }
        let traversal = Task.detached {
            try CaskRemovalFileSystem.walk(fixture.home.path, budget: .init()) { _, depth in
                if depth > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            }
        }
        do { try await traversal.value; XCTFail("Traversal must observe cancellation between entries") }
        catch is CancellationError { }
    }

    func testPrivilegedBoundaryRejectsBroadPathsTraversalAndNonRemovalActions() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        for suffix in ["", "Library", "Documents/project", "Library/Caches", "Library/Caches/../Preferences"] {
            XCTAssertFalse(CaskRemovalAuthorizationRequest.allows(fixture.home.appending(path: suffix).path, home: fixture.home.path))
        }
        XCTAssertTrue(CaskRemovalAuthorizationRequest.allows(fixture.home.appending(path: "Library/Caches/com.acme.sample").path, home: fixture.home.path))
        let request = CaskRemovalAuthorizationRequest(userID: 0, home: fixture.home.path, ownerPID: getpid(),
            expiresAt: Date().addingTimeInterval(60), lease: fixture.home.appending(path: "lease").path,
            entries: [], removal: .init(displayName: "test", appURL: nil, entries: [], warnings: [], ownershipFingerprint: ""))
        XCTAssertThrowsError(try request.validate())
        XCTAssertNil(CaskRemovalPrivilegedMode.run(arguments: ["Cellar"]))
    }

    func testAuthorizationRejectsChangedHomeExpiredRequestAndUnconfirmedEntry() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        let entry = try fixture.entry(fixture.file("Library/Caches/Sample/item").deletingLastPathComponent())
        let removal = CaskRemovalPlan(displayName: "Sample", appURL: nil, entries: [entry], warnings: [], ownershipFingerprint: "")
        let now = Date()
        let valid = CaskRemovalAuthorizationRequest(userID: 501, home: fixture.home.path, ownerPID: getpid(),
            expiresAt: now.addingTimeInterval(60), lease: fixture.home.appending(path: "lease").path, entries: [entry], removal: removal)
        XCTAssertNoThrow(try valid.validate(ownerHome: fixture.home.path, now: now))
        XCTAssertThrowsError(try valid.validate(ownerHome: "/Users/another-user", now: now))
        XCTAssertThrowsError(try valid.validate(ownerHome: fixture.home.path, now: now.addingTimeInterval(120)))
        let changed = CaskRemovalEntry(path: entry.path, category: .cache, estimatedBytes: nil, disposition: .remove, fingerprint: "changed")
        let tampered = CaskRemovalAuthorizationRequest(userID: 501, home: fixture.home.path, ownerPID: getpid(),
            expiresAt: now.addingTimeInterval(60), lease: valid.lease, entries: [changed], removal: removal)
        XCTAssertThrowsError(try tampered.validate(ownerHome: fixture.home.path, now: now))
    }

    func testNonAppSymlinkInApplicationsDoesNotMarkScanIncomplete() throws {
        let fixture = try RemovalFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Sample", bundle: "com.acme.sample")
        let cache = try fixture.file("Library/Caches/com.acme.sample/data.bin")
        let helperTarget = fixture.home.appending(path: "helper-dir")
        try FileManager.default.createDirectory(at: helperTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.apps.appending(path: "Utilities"), withDestinationURL: helperTarget)

        let package = fixture.package(extraArtifacts: [
            .init(kind: "trash", values: ["~/Library/Caches/com.acme.sample"], category: .zap)
        ])
        let plan = try fixture.scanner.scan(package: package, cache: fixture.home.appending(path: "Library/Caches/Homebrew"), otherCasks: [])
        XCTAssertFalse(plan.warnings.contains(.incompleteScan))
        XCTAssertTrue(plan.entries.contains { $0.path == cache.deletingLastPathComponent().path && $0.disposition == .remove })
    }
}

private struct RemovalFixture: Sendable {
    let home: URL
    var apps: URL { home.appending(path: "Applications") }
    var scanner: CaskRemovalScanner { .init(home: home, applicationRoots: [apps]) }

    init() throws {
        home = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory).appending(path: "CellarRemoval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "Applications"), withIntermediateDirectories: true)
    }

    func app(_ name: String, bundle: String) throws -> URL {
        let app = apps.appending(path: name + ".app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle], format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    @discardableResult func file(_ relative: String) throws -> URL {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func package(name: String = "Sample", kind: HomebrewPackageKind = .cask, extraArtifacts: [HomebrewCaskArtifact] = [], installedArtifacts: [HomebrewCaskArtifact]? = nil) -> HomebrewPackage {
        .init(identity: .init(name: name.lowercased().replacingOccurrences(of: " ", with: "-"), kind: kind),
            displayName: name, description: nil, homepage: nil, installedVersions: ["3.0"], currentVersion: "3.0", tap: "homebrew/cask",
            dependencies: [], pinned: false, deprecated: false, disabled: false,
            artifacts: (installedArtifacts ?? [.init(kind: "app", values: [name + ".app"], category: .installed, application: .init(source: name + ".app", target: nil))])
                + [.init(kind: "trash", values: ["~/Documents/" + name], category: .zap)] + extraArtifacts)
    }

    func scan(name: String = "Sample", confirmedCache: URL? = nil, others: [HomebrewPackage] = []) throws -> CaskRemovalPlan {
        try scanner.scan(package: package(name: name), cache: home.appending(path: "Library/Caches/Homebrew"),
                         otherCasks: others, confirmedCachePath: confirmedCache)
    }

    func entry(_ url: URL) throws -> CaskRemovalEntry {
        .init(path: url.path, category: .cache, estimatedBytes: nil, disposition: .remove,
              fingerprint: try CaskRemovalFileSystem.fingerprint(url.path))
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}
