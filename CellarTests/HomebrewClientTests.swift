import XCTest
@testable import Cellar

final class HomebrewClientTests: XCTestCase {
    func testFormulaTargetVersionIncludesHomebrewRevision() throws {
        let json = #"{"name":"demo","full_name":"demo","tap":"homebrew/core","versions":{"stable":"1.2.3"},"revision":2,"installed":[{"version":"1.2.3_2"}],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}"#
        let package = try JSONDecoder().decode(BrewFormulaPayload.self, from: Data(json.utf8)).model
        XCTAssertEqual(package.currentVersion, "1.2.3_2")
        XCTAssertEqual(package.installedVersions, ["1.2.3_2"])
    }

    @MainActor
    func testActualHomebrewBatchRenewsAgedPlansCanonicalizesAndSkipsInstalledDependency() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "install-dependency"))
        let coordinator = BatchOperationCoordinator(provider: HomebrewFixtureBatchProvider(client: fixture.client, agePreparedPlans: true), operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["new-alias", "homebrew/core/newpkg", "batchpkg"].map { .homebrew(.init(name: $0, kind: .formula)) }))
        let confirmed = try await coordinator.prepare(intent)
        XCTAssertEqual(confirmed.intent.items.map(\.displayIdentifier), ["newpkg", "batchpkg"])
        XCTAssertTrue(confirmed.homebrewImpacts.allSatisfy { Date().timeIntervalSince($0.generatedAt) > 300 })
        let result = try await coordinator.execute(confirmed)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .skipped])
        XCTAssertEqual(result.outcome.succeededItemCount, 1)
        XCTAssertEqual(result.outcome.itemOutcomes[1].reason, .alreadySatisfied)
        XCTAssertEqual(result.refreshStatus, .succeeded)
        let writes = try String(contentsOf: fixture.logURL, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("install ") }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].hasPrefix("install --formula newpkg|"))
    }

    func testInstallAndUpgradeUnknownWhenDestinationObservationFails() async throws {
        for action: HomebrewAction in [.install, .upgrade] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let plan = try await (action == .install ? fixture.client.planInstall(.init(name: "newpkg", kind: .formula)) : fixture.client.planUpgrade([.init(name: "acme/tools/demo", kind: .formula)]))
            try Data().write(to: fixture.directoryURL.appending(path: "postflight-configuration-fails"))
            let result = try await fixture.client.execute(plan)
            XCTAssertEqual(result.outcome, .stateUnknown)
            XCTAssertNotNil(result.snapshot?.sectionErrors[.configuration])
        }
    }

    func testBatchRenewsAgedConfirmationWithoutExtendingSingleItemExpiry() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        var aged = try await fixture.client.planInstall(.init(name: "newpkg", kind: .formula))
        aged = HomebrewActionPlan(id: aged.id, action: aged.action, targets: aged.targets, tapName: nil,
            dependencies: aged.dependencies, dependents: [], artifacts: [], residualPaths: [], associatedPackages: [],
            generatedAt: Date().addingTimeInterval(-601), stateFingerprint: aged.stateFingerprint, confirmedTargets: aged.confirmedTargets)
        do { _ = try await fixture.client.execute(aged); XCTFail("Single-item expiry must remain") }
        catch { guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected expiry") } }
        let renewed = try await fixture.client.renewBatchPlan(aged)
        let fresh = try XCTUnwrap(renewed)
        XCTAssertLessThan(Date().timeIntervalSince(fresh.generatedAt), 300)
        XCTAssertEqual(fresh.confirmedTargets, aged.confirmedTargets)
        let result = try await fixture.client.execute(fresh)
        XCTAssertTrue(result.succeeded)
    }

    func testUnknownHomebrewSourceOrVersionCannotPrepareAWritableConfirmation() async throws {
        for field in ["source", "version"] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let source = field == "source" ? "" : "homebrew/core"
            let version = field == "version" ? "" : "1.0.0"
            let json = #"{"formulae":[{"name":"newpkg","full_name":"newpkg","tap":"\#(source)","versions":{"stable":"\#(version)"},"installed":[],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}"#
            try Data(json.utf8).write(to: fixture.directoryURL.appending(path: "new-metadata.json"))
            do { _ = try await fixture.client.planInstall(.init(name: "newpkg", kind: .formula)); XCTFail("Unknown target material must refuse preparation") }
            catch { guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected state changed") } }
            XCTAssertFalse(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("install --formula"))
        }
    }

    func testBatchRenewalRejectsVersionSourceAndPrefixDriftWithoutWriting() async throws {
        for change in ["version", "source", "prefix"] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planInstall(.init(name: "newpkg", kind: .formula))
            if change == "prefix" {
                try Data().write(to: fixture.directoryURL.appending(path: "prefix-changed"))
            } else {
                let version = change == "version" ? "2.0.0" : "1.0.0"
                let source = change == "source" ? "other/tap" : "homebrew/core"
                let json = #"{"formulae":[{"name":"newpkg","aliases":["new-alias"],"full_name":"newpkg","tap":"\#(source)","versions":{"stable":"\#(version)"},"installed":[],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}"#
                try Data(json.utf8).write(to: fixture.directoryURL.appending(path: "new-metadata.json"))
            }
            do { _ = try await fixture.client.renewBatchPlan(plan); XCTFail("Drift: \(change)") }
            catch { guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected state changed: \(error)") } }
            XCTAssertFalse(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("install --formula"))
        }
    }

    func testDependencyInstalledAtConfirmedVersionIsSkippedAndWrongVersionRefused() async throws {
        for wrongVersion in [false, true] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planInstall(.init(name: "batchpkg", kind: .formula))
            try Data().write(to: fixture.directoryURL.appending(path: "install-dependency"))
            if wrongVersion { try Data().write(to: fixture.directoryURL.appending(path: "wrong-dependency-version")) }
            let first = try await fixture.client.planInstall(.init(name: "newpkg", kind: .formula))
            _ = try await fixture.client.execute(first)
            if wrongVersion {
                do { _ = try await fixture.client.renewBatchPlan(plan); XCTFail("A different installed version must not skip") }
                catch { guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected refusal") } }
            } else {
                let renewed = try await fixture.client.renewBatchPlan(plan)
                XCTAssertNil(renewed)
            }
            XCTAssertFalse(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("install --formula batchpkg"))
        }
    }

    func testCanonicalMetadataAcceptsAliasesOldTokensAndCorePrefixButRejectsUnrelatedNames() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        for name in ["newpkg", "homebrew/core/newpkg", "new-alias", "homebrew/core/new-alias"] {
            let package = try await fixture.client.loadPackage(.init(name: name, kind: .formula))
            XCTAssertEqual(package.identity.name, "newpkg")
        }
        let cask = try await fixture.client.loadPackage(.init(name: "old-sample", kind: .cask))
        XCTAssertEqual(cask.identity.name, "acme/apps/sample")
        for name in ["unrelated", "other/tap/newpkg"] {
            do { _ = try await fixture.client.loadPackage(.init(name: name, kind: .formula)); XCTFail("Unrelated response must be refused") }
            catch { guard case HomebrewClientError.invalidJSON = error else { return XCTFail("Expected identity refusal") } }
        }
    }

    func testUpgradeWithoutInstalledTargetIsFailedOrUnknownWhenObservationFails() async throws {
        for unreadable in [false, true] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planUpgrade([.init(name: "acme/tools/demo", kind: .formula)])
            try Data().write(to: fixture.directoryURL.appending(path: "upgrade-removes-target"))
            if unreadable { try Data().write(to: fixture.directoryURL.appending(path: "postflight-packages-fail")) }
            let result = try await fixture.client.execute(plan)
            XCTAssertEqual(result.command.terminationStatus, 0)
            XCTAssertEqual(result.outcome, unreadable ? .stateUnknown : .failed)
            if !unreadable {
                XCTAssertFalse(result.snapshot?.packages.contains { $0.identity == plan.targets[0] && $0.isInstalled } == true)
            }
        }
    }

    func testUpgradeRequiresInstalledConfirmedVersionEvenWhenOutdatedIsEmpty() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planUpgrade([.init(name: "acme/tools/demo", kind: .formula)])
        try Data().write(to: fixture.directoryURL.appending(path: "upgrade-leaves-old-version"))
        let result = try await fixture.client.execute(plan)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.snapshot?.outdatedPackages.isEmpty == true)
    }

    func testFinalProgressReportsARecreatedPathAsRetained() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        _ = try fixture.installSampleApplication()
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        let recorder = CaskProgressRecorder()
        let plan = try await fixture.client.planCaskRemoval("sample")
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { event in
            await recorder.record(event)
            if event.path == preferences.path, event.status == .removed {
                do { try Data("recreated".utf8).write(to: preferences) }
                catch { XCTFail("Could not recreate isolated preference: \(error)") }
            }
        })
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertTrue(result.remainingResidualPaths.contains { $0.path == preferences.path })
        let events = await recorder.events
        XCTAssertEqual(events.last { $0.path == preferences.path }?.status, .retained)
    }

    func testRenamedInstallationUsesOldTokenConfigurationWithoutChangingBrewTarget() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        let customApp = fixture.directoryURL.appending(path: "Custom Apps/Sample.app")
        try FileManager.default.createDirectory(at: customApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: customApp)
        let oldRoot = fixture.directoryURL.appending(path: "Caskroom/old-sample")
        try FileManager.default.moveItem(at: fixture.directoryURL.appending(path: "Caskroom/sample"), to: oldRoot)
        let casks = oldRoot.appending(path: ".metadata/3.0/20260101000000.000/Casks")
        try FileManager.default.moveItem(at: casks.appending(path: "sample.json"), to: casks.appending(path: "old-sample.json"))
        try JSONSerialization.data(withJSONObject: ["explicit": ["appdir": customApp.deletingLastPathComponent().path]])
            .write(to: oldRoot.appending(path: ".metadata/config.json"))

        let plan = try await fixture.client.planCaskRemoval("sample")
        XCTAssertEqual(plan.targets, [.init(name: "acme/apps/sample", kind: .cask)])
        let removal = try XCTUnwrap(plan.caskRemoval)
        XCTAssertEqual(removal.appURL?.path, customApp.path)
        XCTAssertEqual(removal.applicationIdentities.map(\.bundleIdentifier), ["com.acme.sample"])
        XCTAssertFalse(removal.warnings.contains(.incompleteScan))
    }

    func testLegacyAPISnapshotUsesResolvedReceiptAndInstalledVersion() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        let source = fixture.directoryURL.appending(path: "Caskroom/sample/.metadata/3.0/20260101000000.000/Casks/sample.json")
        try JSONSerialization.data(withJSONObject: ["token": "sample", "version": "4.0", "url": "https://example.test/app.dmg",
            "artifacts": [["app": ["Different Platform.app"]], ["zap": [["trash": ["/$HOME/Library/Application Support/Base"]]]]],
            "variations": ["arm64_sequoia": ["version": "3.0"]]])
            .write(to: source)
        let plan = try await fixture.client.planCaskRemoval("sample")
        let removal = try XCTUnwrap(plan.caskRemoval)
        XCTAssertEqual(removal.appURL?.path, app.path)
        XCTAssertTrue(removal.entries.contains { $0.path.hasSuffix("Preferences/com.acme.sample.plist") && $0.disposition == .remove })
        XCTAssertFalse(removal.warnings.contains(.incompleteScan))
    }

    func testInstallationChangesWhileQuittingPreventHomebrewFromStarting() async throws {
        let process = await MainActor.run { UninstallApplicationFixture() }
        let fixture = try FakeBrewFixture(applicationLifecycle: .fixture { [process] })
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        let receipt = fixture.directoryURL.appending(path: "Caskroom/sample/.metadata/INSTALL_RECEIPT.json")
        await MainActor.run {
            process.bundleURL = app
            process.onTermination = { try Data("changed installation".utf8).write(to: receipt) }
        }
        let plan = try await fixture.client.planCaskRemoval("sample")
        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("The quit wait must not leave the original installation check stale")
        } catch HomebrewClientError.stateChanged {}
        XCTAssertFalse(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("uninstall --cask"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testInstallationChangesDuringApplicationProgressPreventHomebrewFromStarting() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        let receipt = fixture.directoryURL.appending(path: "Caskroom/sample/.metadata/INSTALL_RECEIPT.json")
        let plan = try await fixture.client.planCaskRemoval("sample")
        do {
            _ = try await fixture.client.execute(plan, caskRemovalProgress: { event in
                if event.path == app.path && event.status == .removing {
                    do {
                        var bytes = try Data(contentsOf: receipt)
                        bytes.append(32)
                        try bytes.write(to: receipt)
                    } catch { XCTFail("Could not update isolated receipt: \(error)") }
                }
            })
            XCTFail("The progress callback must not leave installation authority stale")
        } catch HomebrewClientError.stateChanged {}
        XCTAssertFalse(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("uninstall --cask"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testEnhancedRemovalUsesInstalledArtifactsWhenCurrentRecipeChanges() async throws {
        let process = await MainActor.run { UninstallApplicationFixture() }
        let fixture = try FakeBrewFixture(applicationLifecycle: .fixture { [process] })
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        await MainActor.run { process.bundleURL = app }
        let unrelated = fixture.directoryURL.appending(path: "Library/Application Support/OnlyNewMetadata/data")
        try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: unrelated)
        try Data().write(to: fixture.directoryURL.appending(path: "current-cask-changed"))

        let plan = try await fixture.client.planCaskRemoval("sample")
        let removal = try XCTUnwrap(plan.caskRemoval)
        XCTAssertEqual(removal.appURL?.path, app.path)
        XCTAssertEqual(removal.applicationIdentities.map(\.bundleIdentifier), ["com.acme.sample"])
        XCTAssertFalse(removal.entries.contains { $0.path == unrelated.deletingLastPathComponent().path })
        let result = try await fixture.client.execute(plan)
        XCTAssertEqual(result.outcome, .succeeded)
        let terminated = await MainActor.run { process.isTerminated }
        XCTAssertTrue(terminated, "The installed application must be quit, even if the current recipe names a different app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }

    func testInstalledMetadataChangesInvalidateConfirmationBeforeUninstall() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        _ = try fixture.installSampleApplication()
        let plan = try await fixture.client.planCaskRemoval("sample")
        let receipt = fixture.directoryURL.appending(path: "Caskroom/sample/.metadata/INSTALL_RECEIPT.json")
        var data = try Data(contentsOf: receipt)
        data.append(contentsOf: [10, 32])
        try data.write(to: receipt)
        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("Installed source changes must invalidate the confirmed deletion authority")
        } catch HomebrewClientError.stateChanged {}
        XCTAssertFalse(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("uninstall --cask"))
    }

    func testUnavailableInstalledMetadataDoesNotBorrowCurrentRecipePaths() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        _ = try fixture.installSampleApplication()
        try FileManager.default.removeItem(at: fixture.directoryURL.appending(path: "Caskroom/sample/.metadata/INSTALL_RECEIPT.json"))
        let plan = try await fixture.client.planCaskRemoval("sample")
        let removal = try XCTUnwrap(plan.caskRemoval)
        XCTAssertTrue(removal.warnings.contains(.incompleteScan))
        XCTAssertNil(removal.appURL)
        XCTAssertTrue(removal.applicationIdentities.isEmpty)
        XCTAssertFalse(removal.entries.contains { $0.disposition == .remove && $0.category != .homebrewCache })
    }

    func testRestartDuringApplicationProgressPreventsHomebrewUninstall() async throws {
        let process = await MainActor.run { UninstallApplicationFixture() }
        let fixture = try FakeBrewFixture(applicationLifecycle: CaskApplicationLifecycle.fixture { [process] })
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        await MainActor.run { process.bundleURL = app }
        let plan = try await fixture.client.planCaskRemoval("sample")
        do {
            _ = try await fixture.client.execute(plan, caskRemovalProgress: { progress in
                if progress.path == app.path, progress.status == .removing {
                    await MainActor.run { process.isTerminated = false }
                }
            })
            XCTFail("A restart during the progress callback must prevent Homebrew from starting")
        } catch let error as CaskApplicationLifecycleError {
            XCTAssertEqual(error, .applicationStillRunning(.init(bundleURL: app, bundleIdentifier: "com.acme.sample")))
        }
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("uninstall --cask"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testEnhancedUninstallRefusesToRunHomebrewWhenApplicationRefusesToQuit() async throws {
        let process = await MainActor.run { UninstallApplicationFixture() }
        let fixture = try FakeBrewFixture(applicationLifecycle: CaskApplicationLifecycle.fixture { [process] })
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        await MainActor.run { process.bundleURL = app; process.acceptsTermination = false }
        let plan = try await fixture.client.planCaskRemoval("sample")
        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("A running app that refuses to quit must prevent uninstallation")
        } catch let error as CaskApplicationLifecycleError {
            XCTAssertEqual(error, .terminationRefused(.init(bundleURL: app, bundleIdentifier: "com.acme.sample")))
        }
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("uninstall --cask"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist").path))
    }

    func testChangesWrittenWhileQuittingAreKeptWithoutRefusingTheWholeUninstall() async throws {
        let process = await MainActor.run { UninstallApplicationFixture() }
        let fixture = try FakeBrewFixture(applicationLifecycle: CaskApplicationLifecycle.fixture { [process] })
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        await MainActor.run {
            process.bundleURL = app
            process.onTermination = { try Data("saved-on-quit".utf8).write(to: preferences, options: .atomic) }
        }
        let plan = try await fixture.client.planCaskRemoval("sample")
        let result = try await fixture.client.execute(plan)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertEqual(try String(contentsOf: preferences, encoding: .utf8), "saved-on-quit")
        XCTAssertEqual(result.caskRemovalFailures.map(\.path), [preferences.path])
    }

    func testApplicationRestartDuringProgressDoesNotDeleteTheCurrentPath() async throws {
        let process = await MainActor.run { UninstallApplicationFixture() }
        let fixture = try FakeBrewFixture(applicationLifecycle: CaskApplicationLifecycle.fixture { [process] })
        defer { fixture.remove() }
        let app = try fixture.installSampleApplication()
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        await MainActor.run { process.bundleURL = app }
        let plan = try await fixture.client.planCaskRemoval("sample")
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { progress in
            if progress.path == preferences.path, progress.status == .removing {
                await MainActor.run { process.isTerminated = false }
            }
        })
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
        XCTAssertEqual(result.caskRemovalFailures.map(\.path), [preferences.path])
        XCTAssertEqual(result.caskRemovalFailures.map(\.recoveryReason), [.applicationRunning])
    }

    func testNewSharedOwnerDuringProgressKeepsTheCurrentPath() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        _ = try fixture.installSampleApplication()
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        let newApp = fixture.directoryURL.appending(path: "Applications/New Copy.app/Contents")
        let plan = try await fixture.client.planCaskRemoval("sample")
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { progress in
            if progress.path == preferences.path, progress.status == .removing {
                do {
                    try FileManager.default.createDirectory(at: newApp, withIntermediateDirectories: true)
                    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
                        .write(to: newApp.appending(path: "Info.plist"))
                } catch { XCTFail("Could not create isolated shared-owner fixture: \(error)") }
            }
        })
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
        XCTAssertEqual(result.caskRemovalFailures.map(\.path), [preferences.path])
    }

    func testNewCacheReferenceDuringProgressKeepsTheSharedDownload() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        _ = try fixture.installSampleApplication()
        let cache = fixture.directoryURL.appending(path: "Library/Caches/Homebrew")
        let download = cache.appending(path: "downloads/sample.dmg")
        try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download".utf8).write(to: download)
        let newAlias = cache.appending(path: "other--1.dmg")
        let plan = try await fixture.client.planCaskRemoval("sample")
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { progress in
            if progress.path == download.path, progress.status == .removing {
                do { try FileManager.default.createSymbolicLink(at: newAlias, withDestinationURL: download) }
                catch { XCTFail("Could not create isolated shared-cache fixture: \(error)") }
            }
        })
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertEqual(result.caskRemovalFailures.map(\.path), [download.path])
    }

    func testEnhancedCaskUninstallDeletesOnlyConfirmedOwnedFilesAfterHomebrewSuccess() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = fixture.directoryURL.appending(path: "Applications/Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        let cache = fixture.directoryURL.appending(path: "Library/Caches/Homebrew")
        try FileManager.default.createDirectory(at: cache.appending(path: "downloads"), withIntermediateDirectories: true)
        let download = cache.appending(path: "downloads/sample.dmg")
        try Data("download".utf8).write(to: download)
        let unrelated = cache.appending(path: "other--1.dmg")
        try Data("other".utf8).write(to: unrelated)
        let plan = try await fixture.client.planCaskRemoval("sample")
        XCTAssertNotNil(plan.caskRemoval)
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
        let progress = CaskProgressRecorder()
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { await progress.record($0) })
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertTrue(result.caskRemovalFailures.isEmpty)
        XCTAssertFalse(CaskRemovalFileSystem.exists(preferences.path))
        XCTAssertFalse(CaskRemovalFileSystem.exists(download.path))
        XCTAssertTrue(CaskRemovalFileSystem.exists(unrelated.path))
        let events = await progress.events
        let observedRemoval = await progress.existedWhenRemoving
        for entry in try XCTUnwrap(plan.caskRemoval).entries where entry.disposition != .protected {
            XCTAssertEqual(events.filter { $0.path == entry.path }.last?.status, .removed)
            XCTAssertFalse(CaskRemovalFileSystem.exists(entry.path))
        }
        XCTAssertTrue(observedRemoval[preferences.path] == true)
        XCTAssertTrue(events.contains(.init(path: preferences.path, status: .removing)))
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall --cask acme/apps/sample|1|1|1"))
        for forbidden in ["--zap", "autoremove", "cleanup", "sudo", "update|"] { XCTAssertFalse(log.contains(forbidden)) }
    }

    func testEnhancedCaskUninstallFailureKeepsAllUserData() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = fixture.directoryURL.appending(path: "Applications/Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        try Data().write(to: fixture.directoryURL.appending(path: "cask-uninstall-fails"))
        let plan = try await fixture.client.planCaskRemoval("sample")
        let progress = CaskProgressRecorder()
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { await progress.record($0) })
        XCTAssertEqual(result.outcome, .failed)
        let events = await progress.events
        XCTAssertFalse(events.contains { $0.status == .removed })
        XCTAssertTrue(events.filter { $0.path == app.deletingLastPathComponent().path }.last?.status == .retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist").path))
    }

    func testEnhancedCaskCleanupIdentityFailureReportsPartialWithoutDeletingReplacement() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = fixture.directoryURL.appending(path: "Applications/Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        let plan = try await fixture.client.planCaskRemoval("sample")
        try Data().write(to: fixture.directoryURL.appending(path: "replace-preferences"))
        let progress = CaskProgressRecorder()
        let result = try await fixture.client.execute(plan, caskRemovalProgress: { await progress.record($0) })
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.caskRemovalFailures.count, 1)
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        XCTAssertEqual(try String(contentsOf: preferences, encoding: .utf8), "replacement")
        let events = await progress.events
        XCTAssertEqual(events.filter { $0.path == preferences.path }.last?.status, .retained)
        XCTAssertFalse(events.contains(.init(path: preferences.path, status: .removed)))
        XCTAssertEqual(events.filter { $0.path == app.deletingLastPathComponent().path }.last?.status, .removed)
    }

    func testExternalCancellationAfterHomebrewRemovalReconcilesPathsWithoutContinuingCleanup() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = fixture.directoryURL.appending(path: "Applications/Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        let plan = try await fixture.client.planCaskRemoval("sample")
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        let progress = CaskProgressRecorder()
        let cleanupStarted = expectation(description: "Cleanup reached preferences after Homebrew removal")
        let (cleanupRelease, release) = AsyncStream<Void>.makeStream()
        let client = fixture.client
        let execution = Task {
            try await client.execute(plan, caskRemovalProgress: { event in
                await progress.record(event)
                if event.path == preferences.path, event.status == .removing {
                    cleanupStarted.fulfill()
                    for await _ in cleanupRelease { break }
                }
            })
        }
        await fulfillment(of: [cleanupStarted], timeout: 5)
        execution.cancel()
        release.yield(())
        release.finish()
        do { _ = try await execution.value; XCTFail("Cancellation must remain an interruption") }
        catch is CancellationError {}
        let events = await progress.events
        XCTAssertFalse(CaskRemovalFileSystem.exists(app.deletingLastPathComponent().path))
        XCTAssertTrue(CaskRemovalFileSystem.exists(preferences.path), "Read-only reconciliation must not resume deletion")
        XCTAssertEqual(events.filter { $0.path == app.deletingLastPathComponent().path }.last?.status, .removed)
        XCTAssertEqual(events.filter { $0.path == preferences.path }.last?.status, .retained)
    }

    func testEnhancedCaskProgressDoesNotReportRemovalWhenPostflightIsUnavailable() async throws {
        for marker in ["postflight-fails", "postflight-packages-fail"] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let app = fixture.directoryURL.appending(path: "Applications/Sample.app/Contents")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
                .write(to: app.appending(path: "Info.plist"))
            let plan = try await fixture.client.planCaskRemoval("sample")
            try Data().write(to: fixture.directoryURL.appending(path: marker))
            let progress = CaskProgressRecorder()
            let result = try await fixture.client.execute(plan, caskRemovalProgress: { await progress.record($0) })
            let events = await progress.events
            XCTAssertEqual(result.outcome, .stateUnknown)
            XCTAssertFalse(events.contains { $0.status == .removed }, marker)
            for entry in try XCTUnwrap(plan.caskRemoval).entries {
                let expected: CaskRemovalPathStatus = entry.disposition == .homebrew ? .unverified : .retained
                XCTAssertEqual(events.filter { $0.path == entry.path }.last?.status, expected)
            }
        }
    }

    func testEnhancedCaskProgressRetainsUnremovedPathsWhenExecutionIsCancelled() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let app = fixture.directoryURL.appending(path: "Applications/Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        let plan = try await fixture.client.planCaskRemoval("sample")
        let preferences = fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist")
        let progress = CaskProgressRecorder()
        let client = fixture.client
        let execution = Task {
            try await client.execute(plan, caskRemovalProgress: { event in
                await progress.record(event)
                if event.path == preferences.path, event.status == .removing {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        do { _ = try await execution.value; XCTFail("Cancellation must remain an interruption") }
        catch is CancellationError {}
        let events = await progress.events
        XCTAssertTrue(CaskRemovalFileSystem.exists(preferences.path))
        XCTAssertEqual(events.filter { $0.path == preferences.path }.last?.status, .retained)
        XCTAssertFalse(events.contains(.init(path: preferences.path, status: .removed)))
        XCTAssertEqual(events.filter { $0.path == app.deletingLastPathComponent().path }.last?.status, .removed)
    }

    func testEnhancedCaskUninstallRejectsAddedOwnerBeforeAnyMutation() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planCaskRemoval("sample")
        let sibling = fixture.directoryURL.appending(path: "Applications/Other.app/Contents")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: sibling.appending(path: "Info.plist"))
        do { _ = try await fixture.client.execute(plan); XCTFail("Changed owners invalidate confirmation") }
        catch HomebrewClientError.stateChanged {}
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("uninstall --cask"))
    }

    @MainActor
    func testDoctorUsesSharedBoundedRedactedSessionDiagnosticsOnly() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let stdout = "API_KEY=doctor-secret\n" + String(repeating: "out ", count: 530_000)
        let stderr = "Cookie: session=doctor-cookie\n" + String(repeating: "err ", count: 530_000)
        try Data(stdout.utf8).write(to: fixture.directoryURL.appending(path: "doctor.stdout"))
        try Data(stderr.utf8).write(to: fixture.directoryURL.appending(path: "doctor.stderr"))
        let model = fixture.model(activityStore: ActivityStore())
        await model.diagnoseHomebrew()
        let diagnostic = try XCTUnwrap(model.activityDiagnostics.records.first)
        XCTAssertEqual(diagnostic.standardOutput.count, ActivityDiagnosticRecord.textLimit)
        XCTAssertEqual(diagnostic.standardError.count, ActivityDiagnosticRecord.textLimit)
        XCTAssertTrue(diagnostic.wasTruncated)
        let copied = diagnostic.copyText(locale: Locale(identifier: "en"))
        XCTAssertFalse(copied.contains("doctor-secret"))
        XCTAssertFalse(copied.contains("doctor-cookie"))
        XCTAssertTrue(copied.contains("Standard Output"))
        XCTAssertTrue(copied.contains("Standard Error"))
        XCTAssertTrue(copied.contains("sensitive information"))
        XCTAssertTrue(copied.contains("truncated"))
        let history = try XCTUnwrap(model.activityStore)
        XCTAssertTrue(history.summaries.isEmpty)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let tools = try String(contentsOf: root.appending(path: "Features/Tools/DiagnosticsToolsView.swift"), encoding: .utf8)
        let activity = try String(contentsOf: root.appending(path: "Features/TaskFeedbackView.swift"), encoding: .utf8)
        XCTAssertTrue(tools.contains("ActivityDiagnosticsView("))
        for raw in ["standardOutput", "standardError", "model.activities"] { XCTAssertFalse(activity.contains(raw), raw) }
        XCTAssertFalse(tools.contains("report.command.standardOutput"))
    }

    @MainActor
    func testTapAndMetadataKeepHomebrewContextTargetsAndSessionResults() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        var contexts: [ActiveOperationContext] = []
        let subscription = model.operationStore.$currentOperation.sink { if let operation = $0 { contexts.append(operation.context) } }
        await model.prepareHomebrewAddTap("newco/apps")
        await model.executeHomebrewPlan()
        let tap = try XCTUnwrap(store.summaries.first)
        XCTAssertNotNil(tap.scope)
        XCTAssertEqual(tap.targetDisplayNames, ["newco/apps"])
        XCTAssertTrue(contexts.contains { $0.targets == ["newco/apps"] && $0.scope != nil })
        XCTAssertEqual(store.summaries.count, 1)
        await model.prepareHomebrewRemoveTap("newco/apps")
        await model.executeHomebrewPlan()
        XCTAssertEqual(store.summaries.first?.targetDisplayNames, ["newco/apps"])
        await model.performHomebrewMetadataUpdate()
        let metadata = try XCTUnwrap(store.summaries.first)
        XCTAssertNotNil(metadata.scope)
        let renderer = ActivityRenderer(locale: .init(identifier: "en"))
        XCTAssertFalse(renderer.target(metadata).isEmpty)
        XCTAssertTrue(renderer.scope(metadata.scope).contains("Homebrew"))
        XCTAssertTrue(contexts.contains { $0.operation == .updateHomebrewMetadata && $0.scope != nil })
        let restored = ActivityStore()
        XCTAssertTrue(restored.summaries.isEmpty)
        XCTAssertEqual(store.summaries.count, 3)
        XCTAssertTrue(renderer.detail(tap).contains("newco/apps"))
        XCTAssertNotEqual(renderer.detail(metadata), ActivityRenderer(locale: .init(identifier: "zh-Hans")).detail(metadata))
        withExtendedLifetime(subscription) {}
    }

    func testUpgradeRejectsChangedInstalledOrAvailableVersionBeforeWriting() async throws {
        for marker in ["outdated-current-changed", "outdated-installed-changed"] {
            let fixture = try FakeBrewFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planUpgrade([.init(name: "acme/tools/demo", kind: .formula)])
            try Data().write(to: fixture.directoryURL.appending(path: marker))
            do { _ = try await fixture.client.execute(plan); XCTFail("Confirmed upgrade versions changed") }
            catch { guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected upgrade state refusal") } }
            let calls = try String(contentsOf: fixture.logURL, encoding: .utf8)
            XCTAssertFalse(calls.contains("upgrade --formula"))
        }
    }
    @MainActor
    func testFormulaBatchWithUnavailablePackagesFailsFinalReconciliation() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let coordinator = BatchOperationCoordinator(provider: HomebrewFixtureBatchProvider(client: fixture.client), operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .uninstall, items: [.homebrew(.init(name: "acme/tools/demo", kind: .formula))]))
        let plan = try await coordinator.prepare(intent)
        try Data().write(to: fixture.directoryURL.appending(path: "postflight-packages-fail"))
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.unknown])
        XCTAssertEqual(result.refreshStatus, .failed)
        guard case .homebrew(let status) = result.refreshedState else {
            return XCTFail("The final partial snapshot must remain available for independent section publication")
        }
        let partial = try XCTUnwrap(status.snapshot)
        XCTAssertNotNil(partial.sectionErrors[.packages])
        XCTAssertNil(partial.sectionErrors[.configuration])
        XCTAssertNil(partial.sectionErrors[.taps])
        XCTAssertFalse(partial.taps.isEmpty)
    }
    @MainActor
    func testCaskStandardBatchUsesConservativeFlagsAndNeverDeletesArtifacts() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let coordinator = BatchOperationCoordinator(provider: HomebrewFixtureBatchProvider(client: fixture.client), operationStore: OperationStore())
        let identity = HomebrewPackageIdentity(name: "acme/apps/sample", kind: .cask)
        let intent = try XCTUnwrap(BatchIntent(operation: .uninstall, items: [.homebrew(identity)]))
        let plan = try await coordinator.prepare(intent)
        XCTAssertEqual(plan.homebrewImpacts.first?.action, .uninstallCask)
        let before = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(before.contains("uninstall --cask"))
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded])
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall --cask acme/apps/sample|1|1|1"))
        for forbidden in ["--zap", "autoremove", "cleanup", "rm "] { XCTAssertFalse(log.contains(forbidden), forbidden) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directoryURL.appending(path: "Library/Preferences/com.acme.sample.plist").path))
    }
    func testCoreSnapshotDoesNotRunOutdatedAndEnrichmentPreservesTypedIdentity() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let core = try await fixture.client.loadSnapshot(includingOutdated: false)
        XCTAssertEqual(core.version, "Homebrew 5.0.0")
        XCTAssertEqual(core.packages.count, 2)
        let before = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(before.contains("outdated"))
        let outdated = try await fixture.client.loadOutdatedPackages()
        let enriched = core.replacingOutdated(packages: outdated, error: nil)
        XCTAssertEqual(enriched.packages.map(\.identity), core.packages.map(\.identity))
        XCTAssertEqual(enriched.outdatedPackages.first?.identity, .init(name: "acme/tools/demo", kind: .formula))
        XCTAssertNil(enriched.sectionErrors[.outdated])
    }

    func testLoadsStructuredSnapshotAndIgnoresUnknownJSONFields() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let snapshot = try await fixture.client.loadSnapshot()

        XCTAssertEqual(snapshot.version, "Homebrew 5.0.0")
        XCTAssertEqual(snapshot.configuration.prefix, "/opt/homebrew")
        XCTAssertEqual(snapshot.configuration.cellar, "/opt/homebrew/Cellar")
        XCTAssertEqual(snapshot.configuration.values["CPU"], "arm64")
        XCTAssertEqual(snapshot.packages.map(\.identity.name), ["acme/tools/demo", "acme/apps/sample"])
        XCTAssertEqual(snapshot.packages.first?.dependencies, ["libexample"])
        XCTAssertEqual(snapshot.outdatedPackages.map(\.identity.name), ["acme/tools/demo"])
        XCTAssertEqual(snapshot.taps.first?.name, "acme/tools")
    }

    func testSearchTreatsNoMatchesAsEmptyResults() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let results = try await fixture.client.search("missing")

        XCTAssertTrue(results.isEmpty)
    }

    func testScopedSearchKeepsExactTypeDeduplicatesAndBoundsBeforeDetails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let formula = try await fixture.client.search("same", kind: .formula, limit: 1)
        let cask = try await fixture.client.search("same", kind: .cask, limit: 1)
        XCTAssertEqual(formula.map(\.identity), [.init(name: "same", kind: .formula)])
        XCTAssertEqual(cask.map(\.identity), [.init(name: "same", kind: .cask)])
        let empty = try await fixture.client.search(" \n", kind: .formula)
        XCTAssertTrue(empty.isEmpty)
        do { _ = try await fixture.client.search("same", kind: .formula, limit: 101); XCTFail("Invalid bound") } catch {}
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 2)
        XCTAssertTrue(log.contains("search --formula -- same"))
        XCTAssertTrue(log.contains("search --cask -- same"))
        XCTAssertFalse(log.contains("info"))
    }

    func testDiscoveryOnlyEnrichesTheBoundedTypedMatches() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        let matches = try await fixture.client.discover("bounded", kind: .formula, limit: 1)
        XCTAssertEqual(matches.map(\.identity), [.init(name: "batchpkg", kind: .formula)])
        XCTAssertEqual(matches.first?.currentVersion, "2.0.0")
        XCTAssertEqual(matches.first?.description, "Batch formula")
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 2)
        XCTAssertTrue(log.contains("search --formula -- bounded"))
        XCTAssertTrue(log.contains("info --json=v2 --formula batchpkg"))
        XCTAssertFalse(log.contains("newpkg"))
        XCTAssertFalse(log.contains("--cask"))
        XCTAssertFalse(log.contains("install "))
    }

    func testKeepsInstalledPackagesWhenOutdatedSectionFails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "outdated-fails"))

        let snapshot = try await fixture.client.loadSnapshot()

        XCTAssertEqual(snapshot.packages.count, 2)
        XCTAssertTrue(snapshot.outdatedPackages.isEmpty)
        XCTAssertNotNil(snapshot.sectionErrors[.outdated])
    }

    func testRejectsMismatchedFullyQualifiedPackageIdentity() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.client.loadPackage(
                HomebrewPackageIdentity(name: "other/tools/demo", kind: .formula)
            )
            XCTFail("Expected package identity mismatch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("身份与请求不匹配"))
        }
    }

    func testDoctorReturnsTextDiagnosticsDespiteNonzeroExit() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let report = try await fixture.client.diagnose()
        let diagnostics = report.diagnostics

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(report.command.terminationStatus, 1)
        XCTAssertTrue(report.command.standardOutput.contains("Unbrewed dylibs"))
        XCTAssertTrue(report.command.standardError.contains("Prefix has a problem"))
        XCTAssertTrue(diagnostics.contains { $0.severity == .warning && $0.message == "Warning: Unbrewed dylibs found" })
        XCTAssertTrue(diagnostics.contains { $0.severity == .warning && $0.message == "Prefix has a problem" })
    }

    func testFormulaUninstallUsesConservativeEnvironmentAndRereadsState() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planFormulaUninstall("demo")
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(plan.dependencies, ["libexample"])
        XCTAssertEqual(plan.dependents, ["consumer"])
        XCTAssertEqual(result.command.arguments, ["uninstall", "--formula", "acme/tools/demo"])
        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertNotNil(result.snapshot)
        XCTAssertTrue(result.succeeded)
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall --formula acme/tools/demo|1|1|1"))
        XCTAssertFalse(log.contains("--force"))
        XCTAssertFalse(log.contains("autoremove"))
    }

    func testCaskZapPlanReportsArtifactsWithoutDeletingThemDirectly() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planCaskUninstall("sample", zap: true)
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(plan.artifacts.first(where: { $0.category == .installed })?.values, ["Sample.app"])
        XCTAssertEqual(plan.artifacts.first(where: { $0.category == .zap })?.values, ["~/Library/Preferences/com.acme.sample.plist"])
        XCTAssertEqual(plan.residualPaths.map(\.artifactKind), ["trash"])
        XCTAssertEqual(result.remainingResidualPaths.count, 1)
        XCTAssertEqual(result.command.arguments, ["uninstall", "--cask", "--zap", "acme/apps/sample"])
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall --cask --zap acme/apps/sample|1|1|1"))
        XCTAssertFalse(log.contains("sudo"))
        XCTAssertFalse(log.contains("rm "))
    }

    func testInstallUpgradeUpdateAndTapActionsUseExplicitCommands() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let install = try await fixture.client.planInstall(
            HomebrewPackageIdentity(name: "newpkg", kind: .formula)
        )
        let installResult = try await fixture.client.execute(install)
        XCTAssertEqual(installResult.command.arguments, ["install", "--formula", "newpkg"])
        XCTAssertTrue(installResult.succeeded)

        let upgrade = try await fixture.client.planUpgrade([
            HomebrewPackageIdentity(name: "acme/tools/demo", kind: .formula)
        ])
        let upgradeResult = try await fixture.client.execute(upgrade)
        XCTAssertEqual(upgradeResult.command.arguments, ["upgrade", "--formula", "acme/tools/demo"])
        XCTAssertTrue(upgradeResult.succeeded)

        let updateResult = try await fixture.client.execute(await fixture.client.planUpdate())
        XCTAssertEqual(updateResult.command.arguments, ["update"])
        XCTAssertTrue(updateResult.succeeded)

        let addTap = try await fixture.client.planAddTap("newco/apps")
        let addResult = try await fixture.client.execute(addTap)
        XCTAssertEqual(addResult.command.arguments, ["tap", "newco/apps"])
        XCTAssertTrue(addResult.succeeded)

        let removeTap = try await fixture.client.planRemoveTap("newco/apps")
        let removeResult = try await fixture.client.execute(removeTap)
        XCTAssertEqual(removeResult.command.arguments, ["untap", "newco/apps"])
        XCTAssertTrue(removeResult.succeeded)
    }

    func testBatchInstallUsesOneTypedCommandAndRereadsEveryTarget() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planInstall([
            HomebrewPackageIdentity(name: "newpkg", kind: .formula),
            HomebrewPackageIdentity(name: "batchpkg", kind: .formula),
        ])
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(plan.targets.map(\.name), ["newpkg", "batchpkg"])
        XCTAssertEqual(result.command.arguments, ["install", "--formula", "newpkg", "batchpkg"])
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertTrue(result.snapshot?.packages.contains { $0.identity.name == "newpkg" } == true)
        XCTAssertTrue(result.snapshot?.packages.contains { $0.identity.name == "batchpkg" } == true)
    }

    func testBatchInstallRejectsMixedPackageKinds() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.client.planInstall([
                HomebrewPackageIdentity(name: "newpkg", kind: .formula),
                HomebrewPackageIdentity(name: "sample", kind: .cask),
            ])
            XCTFail("Expected mixed package kinds to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不能混合 Formula 与 Cask"))
        }
    }

    func testBatchInstallRejectsNamesWithTheSameCanonicalIdentity() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.client.planInstall([
                HomebrewPackageIdentity(name: "aliaspkg", kind: .formula),
                HomebrewPackageIdentity(name: "acme/tools/aliaspkg", kind: .formula),
            ])
            XCTFail("Expected canonical duplicates to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("同一个软件包"))
        }
    }

    func testBatchInstallReportsPartialWhenSuccessfulCommandDoesNotReachEveryTarget() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "partial-batch-install"))

        let plan = try await fixture.client.planInstall([
            HomebrewPackageIdentity(name: "newpkg", kind: .formula),
            HomebrewPackageIdentity(name: "batchpkg", kind: .formula),
        ])
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.snapshot?.packages.first { $0.identity.name == "newpkg" }?.installedVersions, ["1.0.0"])
        XCTAssertFalse(result.snapshot?.packages.contains { $0.identity.name == "batchpkg" && $0.isInstalled } == true)
    }

    func testBatchInstallRejectsExecutionWhenAnyTargetChangedAfterPlanning() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planInstall([
            HomebrewPackageIdentity(name: "newpkg", kind: .formula),
            HomebrewPackageIdentity(name: "batchpkg", kind: .formula),
        ])
        try Data().write(to: fixture.directoryURL.appending(path: "batch-installed"))

        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("Expected stale batch install plan rejection")
        } catch {
            guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected semantic state change") }
        }
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("install --formula newpkg batchpkg"))
    }

    func testTapRemovalIsBlockedWhenInstalledPackagesBelongToTap() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planRemoveTap("acme/tools")

        XCTAssertFalse(plan.canExecute)
        XCTAssertEqual(plan.associatedPackages.map(\.name), ["acme/tools/demo"])
    }

    func testRejectsInstallWhenStateChangedAfterPlanning() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planInstall(
            HomebrewPackageIdentity(name: "newpkg", kind: .formula)
        )
        try Data().write(to: fixture.directoryURL.appending(path: "new-installed"))

        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("Expected stale install plan rejection")
        } catch {
            guard case HomebrewClientError.stateChanged = error else { return XCTFail("Expected semantic state change") }
        }
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("install --formula newpkg"))
    }

    func testReportsPartialWhenCommandFailsAfterChangingState() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "uninstall-reports-failure"))

        let plan = try await fixture.client.planFormulaUninstall("demo")
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 1)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertNotNil(result.snapshot)
    }

    func testReportsUnknownStateWhenPostflightRefreshFails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planFormulaUninstall("demo")
        try Data().write(to: fixture.directoryURL.appending(path: "postflight-fails"))
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertEqual(result.outcome, .stateUnknown)
        XCTAssertNil(result.snapshot)
        XCTAssertNotNil(result.postflightError)
    }

    func testReportsUnknownStateWhenPostflightPackageSectionFails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planFormulaUninstall("demo")
        try Data().write(to: fixture.directoryURL.appending(path: "postflight-packages-fail"))
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertEqual(result.outcome, .stateUnknown)
        XCTAssertNotNil(result.snapshot)
        XCTAssertNotNil(result.snapshot?.sectionErrors[.packages])
    }
}

struct FakeBrewFixture {
    let directoryURL: URL
    let brewURL: URL
    let logURL: URL
    let client: HomebrewClient

    init(applicationLifecycle: CaskApplicationLifecycle = .noRunningApplications) throws {
        directoryURL = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarHomebrewClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let preferences = directoryURL.appending(path: "Library/Preferences", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: preferences.appending(path: "com.acme.sample.plist"))
        let metadata = directoryURL.appending(path: "Caskroom/sample/.metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["default": ["appdir": directoryURL.appending(path: "Applications").path]])
            .write(to: metadata.appending(path: "config.json"))
        try JSONSerialization.data(withJSONObject: [
            "source": ["tap": "acme/apps", "version": "3.0"],
            "uninstall_artifacts": [["app": ["Sample.app"]], ["zap": [["trash": ["~/Library/Preferences/com.acme.sample.plist"]]]]]
        ]).write(to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        let installedSource = metadata.appending(path: "3.0/20260101000000.000/Casks")
        try FileManager.default.createDirectory(at: installedSource, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: installedSource.appending(path: "sample.json"))
        brewURL = directoryURL.appending(path: "bin/brew")
        logURL = directoryURL.appending(path: "commands.log")
        try FileManager.default.createDirectory(at: brewURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let script = #"""
        #!/bin/bash
        set -u
        log_path='\#(logURL.path)'
        state_dir='\#(directoryURL.path)'
        printf '%s|%s|%s|%s\n' "$*" "${HOMEBREW_NO_AUTO_UPDATE:-}" "${HOMEBREW_NO_AUTOREMOVE:-}" "${HOMEBREW_NO_INSTALL_CLEANUP:-}" >> "$log_path"

        case "$*" in
          "--prefix")
            [ ! -f "$state_dir/fail-configuration" ] || exit 1
            if [ -f "$state_dir/postflight-configuration-fails" ] && { [ -f "$state_dir/new-installed" ] || [ -f "$state_dir/formula-upgraded" ]; }; then exit 1; fi
            ;;
          "info --json=v2 --installed") [ ! -f "$state_dir/fail-packages" ] || exit 1 ;;
          "tap-info --installed --json=v1") [ ! -f "$state_dir/fail-taps" ] || exit 1 ;;
        esac
        case "$*" in
          "--version")
            if [ -f "$state_dir/postflight-fails" ] && { [ -f "$state_dir/formula-removed" ] || [ -f "$state_dir/cask-removed" ]; }; then
              printf '%s\n' 'postflight unavailable' >&2
              exit 1
            fi
            printf '%s\n' 'Homebrew 5.0.0' 'Homebrew/homebrew-core (git revision test)'
            ;;
          "-p") printf '%s\n' '/Library/Developer/CommandLineTools' ;;
          "--prefix") if [ -f "$state_dir/prefix-changed" ]; then printf '%s\n' /other; else printf '%s\n' /opt/homebrew; fi ;;
          "--repository") printf '%s\n' '/opt/homebrew' ;;
          "--cache") printf '%s\n' "$state_dir/Library/Caches/Homebrew" ;;
          "--cache --cask acme/apps/sample") printf '%s\n' "$state_dir/Library/Caches/Homebrew/downloads/sample.dmg" ;;
          "--cellar") printf '%s\n' '/opt/homebrew/Cellar' ;;
          "--caskroom") printf '%s\n' "$state_dir/Caskroom" ;;
          "config") printf '%s\n' 'HOMEBREW_VERSION: 5.0.0' 'CPU: arm64' ;;
          "info --json=v2 --installed")
            if [ -f "$state_dir/postflight-packages-fail" ] && { [ -f "$state_dir/formula-removed" ] || [ -f "$state_dir/cask-removed" ]; }; then
              printf '%s\n' 'installed package query unavailable' >&2
              exit 1
            fi
            formula='{"name":"demo","full_name":"acme/tools/demo","tap":"acme/tools","desc":"Demo formula","homepage":"https://example.test/demo","versions":{"stable":"2.0.0","head":null,"bottle":true},"installed":[{"version":"1.0.0","future":"ignored"}],"dependencies":["libexample"],"pinned":false,"deprecated":false,"disabled":false,"future":{"nested":true}}'
            if [ -f "$state_dir/formula-upgraded" ] && [ ! -f "$state_dir/upgrade-leaves-old-version" ]; then
              formula="${formula/1.0.0/2.0.0}"
            fi
            cask='{"token":"sample","old_tokens":["old-sample"],"full_token":"acme/apps/sample","tap":"acme/apps","name":["Sample"],"desc":"Sample cask","homepage":"https://example.test/sample","version":"3.0","installed":"3.0","outdated":false,"artifacts":[{"app":["Sample.app"]},{"zap":[{"trash":["~/Library/Preferences/com.acme.sample.plist"]}]}],"future":42}'
            [ -f "$state_dir/formula-removed" ] && formula=''
            [ -f "$state_dir/cask-removed" ] && cask=''
            new_formula=''
            [ -f "$state_dir/new-installed" ] && new_formula='{"name":"newpkg","aliases":["new-alias"],"full_name":"newpkg","tap":"homebrew/core","desc":"New formula","homepage":null,"versions":{"stable":"1.0.0","head":null},"installed":[{"version":"1.0.0"}],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}'
            batch_formula=''
            [ -f "$state_dir/batch-installed" ] && batch_formula='{"name":"batchpkg","full_name":"batchpkg","tap":"homebrew/core","desc":"Batch formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":[{"version":"2.0.0"}],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}'
            formula_list="$formula"
            for candidate in "$new_formula" "$batch_formula"; do
              if [ -n "$formula_list" ] && [ -n "$candidate" ]; then
                formula_list="$formula_list,$candidate"
              elif [ -n "$candidate" ]; then
                formula_list="$candidate"
              fi
            done
            printf '{"formulae":[%s],"casks":[%s],"future":true}\n' "$formula_list" "$cask"
            ;;
          "outdated --json=v2")
            if [ -f "$state_dir/outdated-fails" ]; then
              printf '%s\n' 'outdated unavailable' >&2
              exit 1
            elif [ -f "$state_dir/formula-removed" ] || [ -f "$state_dir/formula-upgraded" ]; then
              printf '%s\n' '{"formulae":[],"casks":[]}'
            else
              outdated_installed=1.0.0
              outdated_current=2.0.0
              [ ! -f "$state_dir/outdated-installed-changed" ] || outdated_installed=1.5.0
              [ ! -f "$state_dir/outdated-current-changed" ] || outdated_current=2.1.0
              printf '{"formulae":[{"name":"acme/tools/demo","installed_versions":["%s"],"current_version":"%s","pinned":false,"pinned_version":null}],"casks":[]}\n' "$outdated_installed" "$outdated_current"
            fi
            ;;
          "tap-info --installed --json=v1")
            extra_tap=''
            if [ -f "$state_dir/tap-added" ] && [ ! -f "$state_dir/tap-removed" ]; then
              extra_tap=',{"name":"newco/apps","path":"/opt/homebrew/Library/Taps/newco/homebrew-apps","remote":"https://github.com/newco/homebrew-apps","official":false,"trusted":false,"formula_names":[],"cask_tokens":[]}'
            fi
            printf '[{"name":"acme/tools","path":"/opt/homebrew/Library/Taps/acme/homebrew-tools","remote":"https://github.com/acme/homebrew-tools","official":false,"trusted":false,"formula_names":["acme/tools/demo"],"cask_tokens":[],"future":"ignored"}%s]\n' "$extra_tap"
            ;;
          "search --formula -- missing"|"search --cask -- missing")
            printf '%s\n' 'No formulae or casks found for "missing".' >&2
            exit 1
            ;;
          "search --formula -- same"|"search --cask -- same")
            printf '%s\n' same same third
            ;;
          "search --formula -- bounded")
            printf '%s\n' newpkg batchpkg batchpkg
            ;;
          "doctor")
            if [ -f "$state_dir/doctor.stdout" ]; then
              /bin/cat "$state_dir/doctor.stdout"
              /bin/cat "$state_dir/doctor.stderr" >&2
              exit 1
            fi
            printf '%s\n' 'Warning: Unbrewed dylibs found'
            printf '%s\n' 'Prefix has a problem' >&2
            exit 1
            ;;
          "info --json=v2 --formula demo"|"info --json=v2 --formula acme/tools/demo")
            printf '%s\n' '{"formulae":[{"name":"demo","full_name":"acme/tools/demo","tap":"acme/tools","desc":"Demo formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":[{"version":"1.0.0"}],"dependencies":["libexample"],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}'
            ;;
          "info --json=v2 --formula other/tools/demo")
            printf '%s\n' '{"formulae":[{"name":"demo","full_name":"acme/tools/demo","tap":"acme/tools","desc":"Demo formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":[],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}'
            ;;
          "info --json=v2 --formula newpkg"|"info --json=v2 --formula homebrew/core/newpkg"|"info --json=v2 --formula new-alias"|"info --json=v2 --formula homebrew/core/new-alias"|"info --json=v2 --formula unrelated"|"info --json=v2 --formula other/tap/newpkg")
            if [ -f "$state_dir/new-metadata.json" ]; then /bin/cat "$state_dir/new-metadata.json"; exit 0; fi
            installed='[]'
            [ -f "$state_dir/new-installed" ] && installed='[{"version":"1.0.0"}]'
            printf '{"formulae":[{"name":"newpkg","aliases":["new-alias"],"full_name":"newpkg","tap":"homebrew/core","desc":"New formula","homepage":null,"versions":{"stable":"1.0.0","head":null},"installed":%s,"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}\n' "$installed"
            ;;
          "info --json=v2 --formula batchpkg")
            installed='[]'
            [ -f "$state_dir/batch-installed" ] && installed='[{"version":"2.0.0"}]'
            [ ! -f "$state_dir/wrong-dependency-version" ] || installed='[{"version":"1.0.0"}]'
            printf '{"formulae":[{"name":"batchpkg","full_name":"batchpkg","tap":"homebrew/core","desc":"Batch formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":%s,"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}\n' "$installed"
            ;;
          "info --json=v2 --formula aliaspkg"|"info --json=v2 --formula acme/tools/aliaspkg")
            printf '%s\n' '{"formulae":[{"name":"aliaspkg","full_name":"acme/tools/aliaspkg","tap":"acme/tools","desc":"Alias formula","homepage":null,"versions":{"stable":"1.0.0","head":null},"installed":[],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}'
            ;;
          "uses --installed --formula acme/tools/demo") printf '%s\n' 'consumer' ;;
          "info --json=v2 --cask sample"|"info --json=v2 --cask old-sample"|"info --json=v2 --cask acme/apps/sample")
            if [ -f "$state_dir/current-cask-changed" ]; then
              printf '%s\n' '{"formulae":[],"casks":[{"token":"sample","old_tokens":["old-sample"],"full_token":"acme/apps/sample","tap":"acme/apps","name":["New Name"],"desc":null,"homepage":null,"version":"4.0","installed":"3.0","outdated":true,"artifacts":[{"app":["NewName.app"]},{"zap":[{"trash":["~/Library/Application Support/OnlyNewMetadata"]}]}]}]}'
              exit 0
            fi
            printf '%s\n' '{"formulae":[],"casks":[{"token":"sample","old_tokens":["old-sample"],"full_token":"acme/apps/sample","tap":"acme/apps","name":["Sample"],"desc":null,"homepage":null,"version":"3.0","installed":"3.0","outdated":false,"artifacts":[{"app":["Sample.app"]},{"zap":[{"trash":["~/Library/Preferences/com.acme.sample.plist"]}]}]}]}'
            ;;
          "uninstall --formula acme/tools/demo")
            touch "$state_dir/formula-removed"
            printf '%s\n' 'completed'
            [ ! -f "$state_dir/uninstall-reports-failure" ] || exit 1
            ;;
          "uninstall --cask --zap acme/apps/sample"|"uninstall --cask acme/apps/sample")
            [ ! -f "$state_dir/cask-uninstall-fails" ] || exit 1
            touch "$state_dir/cask-removed"
            rm -rf "$state_dir/Applications/Sample.app"
            if [ -f "$state_dir/replace-preferences" ]; then
              mv "$state_dir/Library/Preferences/com.acme.sample.plist" "$state_dir/old-preferences"
              printf replacement > "$state_dir/Library/Preferences/com.acme.sample.plist"
            fi
            printf '%s\n' 'completed'
            ;;
          "install --formula newpkg")
            touch "$state_dir/new-installed"
            [ ! -f "$state_dir/install-dependency" ] || touch "$state_dir/batch-installed"
            printf '%s\n' 'installed'
            ;;
          "install --formula newpkg batchpkg")
            touch "$state_dir/new-installed"
            [ -f "$state_dir/partial-batch-install" ] || touch "$state_dir/batch-installed"
            printf '%s\n' 'installed batch'
            ;;
          "upgrade --formula acme/tools/demo")
            touch "$state_dir/formula-upgraded"
            [ ! -f "$state_dir/upgrade-removes-target" ] || touch "$state_dir/formula-removed"
            printf '%s\n' 'upgraded'
            ;;
          "update") printf '%s\n' 'updated' ;;
          "tap newco/apps")
            touch "$state_dir/tap-added"
            printf '%s\n' 'tapped'
            ;;
          "untap newco/apps")
            touch "$state_dir/tap-removed"
            printf '%s\n' 'untapped'
            ;;
          *)
            printf 'unexpected arguments: %s\n' "$*" >&2
            exit 64
            ;;
        esac
        """#
        try Data(script.utf8).write(to: brewURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brewURL.path)
        client = HomebrewClient(
            brewURL: brewURL,
            runner: ProcessRunner(),
            homeDirectoryURL: directoryURL,
            temporaryDirectoryURL: directoryURL,
            userName: "cellar-test",
            developerDirectoryProbeURL: brewURL,
            caskRemovalScanner: CaskRemovalScanner(home: directoryURL, applicationRoots: [directoryURL.appending(path: "Applications")]),
            caskApplicationLifecycle: applicationLifecycle
        )
    }

    func installSampleApplication() throws -> URL {
        let app = directoryURL.appending(path: "Applications/Sample.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acme.sample"], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    @MainActor
    func model(activityStore: ActivityStore) -> AppModel {
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: directoryURL)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: directoryURL),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: .init(homeDirectory: directoryURL)),
                                         environmentResolver: resolver, homebrewClient: client)
        return AppModel(service: service, operationStore: OperationStore(), activityStore: activityStore)
    }
}

@MainActor
private final class UninstallApplicationFixture: CaskRunningApplicationProcess {
    var bundleURL: URL?
    let bundleIdentifier: String? = "com.acme.sample"
    var isTerminated = false
    var acceptsTermination = true
    var onTermination: (() throws -> Void)?

    func requestTermination() -> Bool {
        guard acceptsTermination else { return false }
        do { try onTermination?() }
        catch { XCTFail("Could not write isolated quit fixture: \(error)"); return false }
        isTerminated = true
        return true
    }

    func waitUntilTerminated() async throws { XCTAssertTrue(isTerminated) }
}

private actor CaskProgressRecorder {
    private(set) var events: [CaskRemovalProgress] = []
    private(set) var existedWhenRemoving: [String: Bool] = [:]

    func record(_ progress: CaskRemovalProgress) {
        events.append(progress)
        if progress.status == .removing { existedWhenRemoving[progress.path] = CaskRemovalFileSystem.exists(progress.path) }
    }
}

private struct HomebrewFixtureBatchProvider: BatchOperationProviding {
    enum Unsupported: Error { case operation }
    let client: HomebrewClient
    var agePreparedPlans = false

    func renewHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan? { try await client.renewBatchPlan(plan) }
    func renewNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeActionPlan? { throw Unsupported.operation }

    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan {
        let plan: HomebrewActionPlan
        switch operation {
        case .install: plan = try await client.planInstall(identity)
        case .update: plan = try await client.planUpgrade([identity])
        case .uninstall:
            switch identity.kind {
            case .formula: plan = try await client.planFormulaUninstall(identity.name)
            case .cask: plan = try await client.planCaskUninstall(identity.name, zap: false)
            }
        }
        guard agePreparedPlans else { return plan }
        return HomebrewActionPlan(id: plan.id, action: plan.action, targets: plan.targets, tapName: plan.tapName,
            dependencies: plan.dependencies, dependents: plan.dependents, artifacts: plan.artifacts, residualPaths: plan.residualPaths,
            associatedPackages: plan.associatedPackages, generatedAt: Date().addingTimeInterval(-601), stateFingerprint: plan.stateFingerprint,
            confirmedTargets: plan.confirmedTargets, caskRemoval: plan.caskRemoval)
    }
    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult { try await client.execute(plan) }
    func refreshHomebrew() async throws -> HomebrewStatus {
        let snapshot = try await client.loadSnapshot()
        return HomebrewStatus(executablePath: snapshot.executablePath, version: snapshot.version, managerAvailable: true, snapshot: snapshot)
    }
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan { throw Unsupported.operation }
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult { throw Unsupported.operation }
    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot { throw Unsupported.operation }
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) async throws -> NodeActionPlan { throw Unsupported.operation }
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult { throw Unsupported.operation }
}
