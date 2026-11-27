import Combine
import XCTest
@testable import Cellar

@MainActor
final class DiscoverTests: XCTestCase {
    private let capabilityRoot = FileManager.default.temporaryDirectory.appending(path: "CellarDiscoverCapability-\(UUID())")

    override func setUpWithError() throws {
        let bin = capabilityRoot.appending(path: ".nvm/versions/node/v22.0.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["node", "npm"] {
            let file = bin.appending(path: name)
            try Data("#!/bin/sh\nexit 97\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: capabilityRoot)
    }

    private var environment: NodeEnvironmentContext { NodeEnvironmentContext(identifier: capabilityRoot.appending(path: ".nvm/versions/node/v22.0.0/bin/node").path, nodeVersion: "v22.0.0", npmVersion: "10.0.0") }

    func testPackageEditorLinesIncludeEmptyAndTrailingLines() {
        XCTAssertEqual(PackageEditorLines.starts(in: ""), [0])
        XCTAssertEqual(PackageEditorLines.starts(in: "git\nnode\n"), [0, 4, 9])
        XCTAssertEqual(PackageEditorLines.starts(in: "git\r\n\r\nnode"), [0, 5, 7])
        let starts = PackageEditorLines.starts(in: "📦\n中文\n")
        XCTAssertEqual(starts, [0, 3, 6])
        XCTAssertEqual(PackageEditorLines.currentLine(starts: starts, caret: 2), 0)
        XCTAssertEqual(PackageEditorLines.currentLine(starts: starts, caret: 3), 1)
        XCTAssertEqual(PackageEditorLines.currentLine(starts: starts, caret: 6), 2)
    }

    func testAllSearchKeepsProviderIdentityBoundsAndResolvedNPMSource() async throws {
        let registry = try XCTUnwrap(URL(string: "https://registry.fixture/"))
        let scopedRegistry = try XCTUnwrap(URL(string: "https://scoped.fixture/"))
        let base = DiscoverNPMContext(environment: environment, registryURL: registry)
        let resolved = DiscoverNPMContext(environment: environment, registryURL: scopedRegistry)
        let dependencies = DiscoverSearchDependencies(homebrew: { _, kind, _, concurrency in
            XCTAssertEqual(concurrency, 2)
            return .init(packages: [DiscoverSearchFixture.package("one", kind: kind), DiscoverSearchFixture.package("two", kind: kind)], failedDetailCount: 0)
        }, npm: { _, context, _ in
            XCTAssertEqual(context, resolved)
            return ["one", "two"].map { name in
                NPMCatalogResult(identity: .init(name: name, environment: context.environment), version: "1.0.0",
                                 description: nil, websiteURL: nil, registryURL: context.registryURL)
            }
        }, resolveNPM: { _, _ in resolved })
        let model = DiscoverSearchModel(dependencies: dependencies, operationStore: OperationStore())
        await model.search("one", scope: .all, context: .init(homebrewAvailable: true, npm: base), limit: 1)
        XCTAssertEqual(model.state, .available)
        XCTAssertEqual(model.results.map(\.identity), [.homebrew(.init(name: "one", kind: .formula)),
                                                      .homebrew(.init(name: "one", kind: .cask)),
                                                      .npm(.init(name: "one", environment: environment))])
        XCTAssertEqual(model.resultContext?.npm, resolved)
        XCTAssertTrue(model.unavailableScopes.isEmpty)
    }

    func testAllSearchKeepsSuccessfulSourceWhenOtherSourcesFailOrAreMissing() async {
        let dependencies = DiscoverSearchDependencies(homebrew: { _, kind, _, _ in
            if kind == .cask { throw CatalogSourceError.invalidResponse }
            return .init(packages: [DiscoverSearchFixture.package("one", kind: kind)], failedDetailCount: 0)
        }, npm: { _, _, _ in XCTFail("Missing npm context must not issue a request"); return [] })
        let model = DiscoverSearchModel(dependencies: dependencies, operationStore: OperationStore())
        await model.search("one", scope: .all, context: .init(homebrewAvailable: true, npm: nil))
        XCTAssertEqual(model.state, .available)
        XCTAssertEqual(model.results.map(\.identity), [.homebrew(.init(name: "one", kind: .formula))])
        XCTAssertEqual(model.unavailableScopes, [.homebrewCask, .npm])
        model.invalidate()
        XCTAssertTrue(model.unavailableScopes.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testPartialHomebrewResultsDistinguishFailedDetailsFromEmptyAndResetWarnings() async {
        let dependencies = DiscoverSearchDependencies(homebrew: { query, kind, _, concurrency in
            XCTAssertEqual(concurrency, query == "all" ? 2 : 4)
            if kind == .cask { return .init(packages: [], failedDetailCount: 2) }
            return .init(packages: query == "empty" ? [] : [DiscoverSearchFixture.package("one", kind: kind)],
                         failedDetailCount: query == "empty" ? 0 : 1)
        }, npm: { _, context, _ in
            [.init(identity: .init(name: "npm-one", environment: context.environment), version: "1", description: nil,
                   websiteURL: nil, registryURL: context.registryURL)]
        })
        let store = OperationStore()
        let model = DiscoverSearchModel(dependencies: dependencies, operationStore: store)
        let context = DiscoverContext(homebrewAvailable: true, npm: .init(environment: environment, registryURL: CatalogWebsites.npmRegistry))
        await model.search("partial", scope: .homebrewFormula, context: context)
        XCTAssertEqual(model.state, .available)
        XCTAssertEqual(model.partialScopes, [.homebrewFormula])
        XCTAssertTrue(model.unavailableScopes.isEmpty)
        await model.search("failed", scope: .homebrewCask, context: context)
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.unavailableScopes, [.homebrewCask])
        XCTAssertTrue(model.partialScopes.isEmpty)
        await model.search("empty", scope: .homebrewFormula, context: context)
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.unavailableScopes.isEmpty)
        await model.search("all", scope: .all, context: context)
        XCTAssertEqual(model.state, .available)
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.partialScopes, [.homebrewFormula])
        XCTAssertEqual(model.unavailableScopes, [.homebrewCask])
        model.invalidate()
        XCTAssertTrue(model.partialScopes.isEmpty)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testHomebrewDetailConcurrencyReplenishesOneSlotAndPreservesSearchOrder() async throws {
        for capacity in [2, 4] {
            let firstWave = expectation(description: "Initial bounded wave")
            firstWave.expectedFulfillmentCount = capacity
            let replenished = expectation(description: "One replacement")
            let gate = DetailEnrichmentGate(capacity: capacity, first: { firstWave.fulfill() }, next: { replenished.fulfill() })
            let matches = (0...capacity).map { HomebrewSearchResult(identity: .init(name: "item\($0)", kind: .formula)) }
            let task = Task { try await HomebrewClient.enrichDiscoveryMatches(matches, maximumConcurrentDetails: capacity) {
                await gate.load($0)
            } }
            await fulfillment(of: [firstWave], timeout: 3)
            let initial = await gate.startedCount
            XCTAssertEqual(initial, capacity)
            await gate.release("item\(capacity - 1)")
            await fulfillment(of: [replenished], timeout: 3)
            await gate.releaseAll()
            let result = try await task.value
            XCTAssertEqual(result.packages.map(\.identity), matches.map(\.identity))
            XCTAssertEqual(result.failedDetailCount, 0)
            let peak = await gate.peak
            XCTAssertEqual(peak, capacity)
        }
    }

    func testAllHomebrewCategoriesShareFourDetailSlots() async {
        let firstWave = expectation(description: "Two details per category")
        firstWave.expectedFulfillmentCount = 4
        let replacement = expectation(description: "Each category replenishes one slot")
        replacement.expectedFulfillmentCount = 2
        let gate = DetailEnrichmentGate(capacity: 4, first: { firstWave.fulfill() }, next: { replacement.fulfill() })
        let dependencies = DiscoverSearchDependencies(homebrew: { _, kind, _, capacity in
            let prefix = kind == .formula ? "formula" : "cask"
            let matches = (0...2).map { HomebrewSearchResult(identity: .init(name: "\(prefix)\($0)", kind: kind)) }
            return try await HomebrewClient.enrichDiscoveryMatches(matches, maximumConcurrentDetails: capacity) {
                await gate.load($0)
            }
        }, npm: { _, _, _ in [] })
        let model = DiscoverSearchModel(dependencies: dependencies, operationStore: OperationStore())
        let search = Task { await model.search("all", scope: .all, context: .init(homebrewAvailable: true, npm: nil)) }
        await fulfillment(of: [firstWave], timeout: 3)
        let count = await gate.startedCount
        XCTAssertEqual(count, 4)
        await gate.release("formula0")
        await gate.release("cask0")
        await fulfillment(of: [replacement], timeout: 3)
        await gate.releaseAll()
        await search.value
        let peak = await gate.peak
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(model.results.map(\.identity), ["formula0", "formula1", "formula2"].map { .homebrew(.init(name: $0, kind: .formula)) }
                       + ["cask0", "cask1", "cask2"].map { .homebrew(.init(name: $0, kind: .cask)) })
    }

    func testHomebrewEnrichmentDistinguishesAllFailedAndLegitimateEmpty() async throws {
        let empty = try await HomebrewClient.enrichDiscoveryMatches([], maximumConcurrentDetails: 4) { _ in
            XCTFail("Empty search should not enrich"); throw CatalogSourceError.invalidResponse
        }
        XCTAssertFalse(empty.isUnavailable)
        XCTAssertEqual(empty.failedDetailCount, 0)
        let failed = try await HomebrewClient.enrichDiscoveryMatches([.init(identity: .init(name: "one", kind: .formula))], maximumConcurrentDetails: 4) { _ in
            throw CatalogSourceError.invalidResponse
        }
        XCTAssertTrue(failed.isUnavailable)
        XCTAssertEqual(failed.failedDetailCount, 1)
    }

    func testCancellingHomebrewDetailsWaitsForChildrenAndDoesNotReplenish() async {
        let started = expectation(description: "Four details running")
        started.expectedFulfillmentCount = 4
        let gate = DetailEnrichmentGate(capacity: 4, first: { started.fulfill() }, next: { XCTFail("Cancelled query replenished") })
        let matches = (0...4).map { HomebrewSearchResult(identity: .init(name: "item\($0)", kind: .formula)) }
        let task = Task { try await HomebrewClient.enrichDiscoveryMatches(matches, maximumConcurrentDetails: 4) {
            await gate.load($0)
        } }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await gate.releaseAll()
        do { _ = try await task.value; XCTFail("Cancellation must not become partial success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await gate.startedCount
        let active = await gate.active
        XCTAssertEqual(count, 4)
        XCTAssertEqual(active, 0)
        do {
            _ = try await HomebrewClient.enrichDiscoveryMatches([matches[0]], maximumConcurrentDetails: 4) { _ in throw URLError(.cancelled) }
            XCTFail("Source cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testBatchInputNormalizesUnicodeWhitespaceAndStableDeduplication() throws {
        let intent = try DiscoverBatchInput.intent("\u{2003}one\u{2003}\n\n two \r\none\n", scope: .homebrewFormula, npm: nil)
        XCTAssertEqual(intent.items.map(\.displayIdentifier), ["one", "two"])
        XCTAssertEqual(intent.scope, .homebrew(.formula))
        XCTAssertEqual(intent.operation, .install)
        XCTAssertEqual(try DiscoverBatchInput.intent("one", scope: .homebrewCask, npm: nil).scope, .homebrew(.cask))
    }

    func testBatchInputRejectsEmptyTooManyInvalidAndMixedProviderSpecs() throws {
        for value in [" \n", "--cask firefox", "npm:one", "https://example.test/tool", "@scope/tool", "one\ntwo;touch"] {
            XCTAssertThrowsError(try DiscoverBatchInput.intent(value, scope: .homebrewFormula, npm: nil), value)
        }
        XCTAssertThrowsError(try DiscoverBatchInput.intent((0...100).map { "item\($0)" }.joined(separator: "\n"), scope: .homebrewCask, npm: nil))
        XCTAssertThrowsError(try DiscoverBatchInput.intent("one", scope: .npm, npm: nil))
        let context = DiscoverNPMContext(environment: environment, registryURL: CatalogWebsites.npmRegistry)
        XCTAssertEqual(try DiscoverBatchInput.intent("@scope/tool@1.2.3\none@latest", scope: .npm, npm: context).scope, .npm(environment))
        for value in ["acme/tap/tool", "file:../tool", "one@^1", "one@", "one two"] {
            XCTAssertThrowsError(try DiscoverBatchInput.intent(value, scope: .npm, npm: context), value)
        }
    }

    func testEmptyQuerySendsNoRequestAndScopesRetainSameNameIdentity() async throws {
        let fake = DiscoverSearchFixture()
        let model = DiscoverSearchModel(dependencies: fake.dependencies, operationStore: OperationStore())
        let context = DiscoverContext(homebrewAvailable: true, npm: nil)
        await model.search(" \n\u{2003}", scope: .homebrewFormula, context: context)
        XCTAssertEqual(model.state, .idle)
        let requests = await fake.requestCount()
        XCTAssertEqual(requests, 0)
        await model.search("one", scope: .homebrewFormula, context: context)
        XCTAssertEqual(model.results.first?.identity, .homebrew(.init(name: "one", kind: .formula)))
        await model.search("one", scope: .homebrewCask, context: context)
        XCTAssertEqual(model.results.first?.identity, .homebrew(.init(name: "one", kind: .cask)))
    }

    func testNPMInstallTagCanBePersistedWithoutOutputOrEnvironmentPath() throws {
        let summary = ActivitySummary(id: UUID(), operation: .install, scope: .npm(environment), targetDisplayNames: ["@scope/tool@latest"], date: Date(), status: .succeeded, itemOutcomes: [.init(displayName: "@scope/tool@latest", status: .succeeded, reason: nil)])
        let clean = try ActivitySummarySanitizer.sanitize(summary)
        XCTAssertEqual(clean.targetDisplayNames, ["@scope/tool@latest"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(clean), as: UTF8.self).contains("/fixture"))
    }

    func testSearchBoundsAndIndependentMissingEmptyAndFailureStates() async {
        let fake = DiscoverSearchFixture()
        let model = DiscoverSearchModel(dependencies: fake.dependencies, operationStore: OperationStore())
        let available = DiscoverContext(homebrewAvailable: true, npm: nil)
        await model.search("one", scope: .homebrewFormula, context: .init(homebrewAvailable: false, npm: nil))
        XCTAssertEqual(model.state, .homebrewRequired)
        await model.search("one", scope: .npm, context: available)
        XCTAssertEqual(model.state, .nodeRequired)
        await model.search("one", scope: .npm, context: .init(homebrewAvailable: true, npm: nil, nodeAvailable: true))
        XCTAssertEqual(model.state, .registryRequired)
        await model.search("one", scope: .npm, context: .init(homebrewAvailable: true, npm: nil, nodeAvailable: true, registryAvailable: true))
        XCTAssertEqual(model.state, .nodeRequired)
        await model.search("one", scope: .homebrewFormula, context: available, limit: 101)
        XCTAssertEqual(model.state, .failed)
        await model.search(String(repeating: "x", count: 513), scope: .homebrewFormula, context: available)
        let noRequests = await fake.requestCount()
        XCTAssertEqual(noRequests, 0)
        await model.search("empty", scope: .homebrewFormula, context: available)
        XCTAssertEqual(model.state, .empty)
        await model.search("failed", scope: .homebrewFormula, context: available)
        XCTAssertEqual(model.state, .failed)
        await model.search("many", scope: .homebrewFormula, context: available)
        XCTAssertEqual(model.state, .available)
        XCTAssertEqual(model.results.count, 50)
        let limits = await fake.requestLimits()
        XCTAssertEqual(limits, [50, 50, 50])
    }

    func testReplacingSearchWaitsForOldWorkAndCannotPublishStaleResults() async {
        let started = expectation(description: "Old query started")
        let fake = DeferredDiscoverSearch(onStart: { started.fulfill() })
        let store = OperationStore()
        let model = DiscoverSearchModel(dependencies: fake.dependencies, operationStore: store)
        let context = DiscoverContext(homebrewAvailable: true, npm: nil)
        let first = Task { await model.search("old", scope: .homebrewFormula, context: context) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(model.state, .loading)
        XCTAssertFalse(store.hasActiveOperations)
        XCTAssertTrue(store.hasActiveReadOnlyOperations)
        let replacement = Task { await model.search("new", scope: .homebrewCask, context: context) }
        await Task.yield()
        await fake.finishOld()
        await first.value
        await replacement.value
        XCTAssertEqual(model.results.first?.identity, .homebrew(.init(name: "new", kind: .cask)))
        XCTAssertEqual(model.state, .available)
        XCTAssertFalse(store.hasActiveOperations)
        XCTAssertFalse(store.hasActiveReadOnlyOperations)
    }

    func testInvalidationKeepsTaskRegisteredUntilSearchCleanup() async {
        let started = expectation(description: "Search started")
        let fake = DeferredDiscoverSearch(onStart: { started.fulfill() })
        let store = OperationStore()
        let model = DiscoverSearchModel(dependencies: fake.dependencies, operationStore: store)
        let task = Task { await model.search("old", scope: .homebrewFormula, context: .init(homebrewAvailable: true, npm: nil)) }
        await fulfillment(of: [started], timeout: 3)
        model.invalidate()
        XCTAssertFalse(store.hasActiveOperations)
        XCTAssertTrue(store.hasActiveReadOnlyOperations)
        await fake.finishOld()
        await task.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(store.hasActiveOperations)
        XCTAssertFalse(store.hasActiveReadOnlyOperations)
    }

    func testRegistrySearchUsesDisplayedRegistryAndExactNodeEnvironment() async throws {
        let transport = FakeCatalogTransport(body: Data(#"{"objects":[{"package":{"name":"one","version":"2.0.0","description":"Registry fixture"}}],"total":1}"#.utf8))
        let registry = try XCTUnwrap(URL(string: "https://registry.fixture.invalid/custom"))
        let context = DiscoverNPMContext(environment: environment, registryURL: registry)
        let dependencies = DiscoverSearchDependencies(homebrew: { _, _, _, _ in .init(packages: [], failedDetailCount: 0) }, npm: { query, target, limit in
            try await NPMRegistryClient(registryURL: target.registryURL, http: .init(transport: transport)).search(query, environment: target.environment, limit: limit)
        })
        let model = DiscoverSearchModel(dependencies: dependencies, operationStore: OperationStore())
        await model.search("one", scope: .npm, context: .init(homebrewAvailable: true, npm: context))
        XCTAssertEqual(model.results.first?.identity, .npm(.init(name: "one", environment: environment)))
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url.host, registry.host)
        XCTAssertEqual(requests.first?.url.path, "/custom/-/v1/search")
        XCTAssertEqual(model.resultContext?.npm, context)
    }

    func testCardActionOnlyInstallsMissingItemsAndPreservesVersionStatus() throws {
        let node = snapshot(packages: [
            .init(name: "behind", installedVersion: "1.0.0", wantedVersion: nil, latestVersion: nil),
            .init(name: "current", installedVersion: "2.0.0", wantedVersion: nil, latestVersion: nil),
            .init(name: "ahead", installedVersion: "3.0.0", wantedVersion: nil, latestVersion: nil),
            .init(name: "unknown", installedVersion: "custom", wantedVersion: nil, latestVersion: nil)
        ])
        let statuses: [SemanticVersionStatus] = [.behind, .current, .ahead, .unknown]
        for (name, status) in zip(["behind", "current", "ahead", "unknown"], statuses) {
            let card = npmResult(name).card(homebrew: nil, node: node, activeIntent: nil, running: nil, canInstall: true)
            XCTAssertEqual(card.versionStatus, status)
            XCTAssertEqual(card.primaryAction, .uninstall)
            XCTAssertEqual(card.nodeEnvironment, environment)
        }
        XCTAssertEqual(npmResult("missing").card(homebrew: nil, node: node, activeIntent: nil, running: nil, canInstall: true).primaryAction, .install)
        let package = DiscoverSearchFixture.package("one", kind: .formula)
        let formula = DiscoverResult.homebrew(package).card(homebrew: nil, node: nil, activeIntent: nil, running: nil, canInstall: true)
        XCTAssertEqual(formula.websiteURL?.absoluteString, "https://formulae.brew.sh/formula/one")
        XCTAssertEqual(formula.description, "Fixture")
    }

    func testHomebrewCardUsesAuthoritativeOutdatedVersionsAndPreservesUnknownFailures() throws {
        let package = HomebrewPackage(identity: .init(name: "one", kind: .cask), displayName: "One", description: nil,
                                      homepage: nil, installedVersions: ["custom-old"], currentVersion: "custom-catalog",
                                      tap: nil, dependencies: [], pinned: false, deprecated: false, disabled: false, artifacts: [],
                                      detectedAppVersion: "custom-detected")
        for hasOutdated in [false, true] {
            for failed in [false, true] {
                let snapshot = HomebrewSnapshot(executablePath: "/fake/brew", version: "5.0.0",
                                               configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]),
                                               packages: [package], outdatedPackages: hasOutdated ? [.init(identity: package.identity, installedVersions: package.installedVersions, currentVersion: "custom-latest")] : [],
                                               taps: [], sectionErrors: failed ? [.outdated: "fixture unavailable"] : [:],
                                               controlledPath: "", commandLineToolsAvailable: true)
                let card = DiscoverResult.homebrew(package).card(homebrew: snapshot, node: nil, activeIntent: nil, running: nil, canInstall: true)
                let library = try XCTUnwrap(LibraryCatalog.cards(homebrew: snapshot, node: nil, homebrewUpdates: .available, nodeUpdates: .notLoaded).first)
                XCTAssertEqual(card.currentVersion, library.currentVersion)
                XCTAssertEqual(card.availableVersion, library.availableVersion)
                XCTAssertEqual(card.versionStatus, library.versionStatus)
                XCTAssertEqual(card.versionStatus, failed ? .unknown : hasOutdated ? .behind : .unknown)
                XCTAssertEqual(card.currentVersion, hasOutdated ? "custom-old" : "custom-detected")
                XCTAssertEqual(card.availableVersion, hasOutdated ? "custom-latest" : "custom-catalog")
            }
        }
    }

    func testQueuedInstallFailureIsReportedAfterChangingPage() async throws {
        let model = fixtureModel(FakeBatchProvider(failingNames: ["one"]))
        let installation = DiscoverInstallationModel(model: model)
        let reported = expectation(description: "queued install failure reaches app model")
        let observation = model.$queuedBatchFailureMessage.compactMap { $0 }.sink { _ in reported.fulfill() }
        defer { observation.cancel() }
        let card = npmResult("one").card(homebrew: nil, node: model.node, activeIntent: nil, running: nil, canInstall: true)
        installation.enqueueInstall(card, context: model.discoverContext)
        model.selectedDestination = .home
        await fulfillment(of: [reported], timeout: 3)
        XCTAssertTrue(try XCTUnwrap(model.queuedBatchFailureMessage).hasPrefix("one: "))
        XCTAssertFalse(installation.isQueueActive)
    }

    func testBatchPreviewHasNoMutationAndConfirmationIsConsumedOnce() async throws {
        let provider = FakeBatchProvider(failingNames: ["two"])
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        await installation.preview("one\ntwo\nthree\none", scope: .npm)
        XCTAssertEqual(installation.preview?.intent.items.map(\.displayIdentifier), ["one", "two", "three"])
        XCTAssertEqual(installation.preview?.npm, model.discoverContext.npm)
        let before = await provider.executedNames()
        XCTAssertTrue(before.isEmpty)
        XCTAssertNotNil(model.batchCoordinator.preparedPlan)
        await installation.confirmInstall()
        XCTAssertNil(installation.preview)
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.succeeded, .failed, .succeeded])
        XCTAssertEqual(installation.result?.outcome.status, .partiallySucceeded)
        let names = await provider.executedNames()
        let environments = await provider.executedEnvironments()
        let concurrency = await provider.maximumConcurrentCount()
        XCTAssertEqual(names, ["one", "two", "three"])
        XCTAssertEqual(environments, [environment, environment, environment])
        XCTAssertEqual(concurrency, 1)
        await installation.confirmInstall()
        let replay = await provider.executedNames()
        XCTAssertEqual(replay, names)
    }

    func testPreviewBindsAllPlansBeforeConfirmationAndRejectsDestinationChange() async {
        let provider = FakeBatchProvider()
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        await installation.preview("one\ntwo", scope: .npm)
        let plannedBefore = await provider.preparedNames()
        XCTAssertEqual(plannedBefore, ["one", "two"])
        XCTAssertNotNil(model.batchCoordinator.preparedPlan)
        XCTAssertEqual(installation.preview?.plan.npmBindings.map(\.targetVersion), ["2.0.0", "2.0.0"])
        await provider.changeDestination()
        await installation.confirmInstall()
        let plannedAfter = await provider.preparedNames()
        let executed = await provider.executedNames()
        XCTAssertEqual(plannedAfter, ["one", "two", "one", "two"])
        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.failed, .failed])
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.reason), [.stateChanged, .stateChanged])
    }

    func testLaterItemCannotAdoptDestinationChangedByEarlierItemAfterConfirmation() async {
        let provider = FakeBatchProvider(changeDestinationAfterName: "one")
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        await installation.preview("one\ntwo", scope: .npm)
        XCTAssertEqual(installation.preview?.plan.npmBindings.map(\.destination.globalRoot), ["/fake", "/fake"])
        XCTAssertEqual(installation.preview?.plan.npmBindings.map(\.targetVersion), ["2.0.0", "2.0.0"])
        await installation.confirmInstall()
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.succeeded, .failed])
        let planned = await provider.preparedNames()
        let executed = await provider.executedNames()
        XCTAssertEqual(planned, ["one", "two", "one", "two"])
        XCTAssertEqual(executed, ["one"])
        let specs = await provider.executedSpecs()
        XCTAssertEqual(specs, ["one@2.0.0"])
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.last?.reason, .stateChanged)
    }

    func testPreviewShowsScopedRegistryAndKnownUnavailableItemsAndRejectsMixedSources() async {
        let scoped = CatalogWebsites.url(host: "scope.fixture.invalid", path: "/")
        let provider = FakeBatchProvider(planFailureNames: ["bad"], alreadyInstalledNames: ["installed"], registries: ["@scope/one": scoped])
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        await installation.preview("@scope/one\nbad\ninstalled", scope: .npm)
        XCTAssertEqual(installation.preview?.npm?.registryURL, scoped)
        XCTAssertEqual(installation.preview?.plan.executableCount, 1)
        XCTAssertEqual(installation.preview?.plan.items.map(\.status), [.ready, .unavailable, .alreadyInstalled])
        await installation.preview("@scope/one\nunscoped", scope: .npm)
        XCTAssertNil(installation.preview)
        XCTAssertEqual(installation.error, .mixedRegistries)
        let executed = await provider.executedNames()
        XCTAssertTrue(executed.isEmpty)
    }

    func testCancellingPreviewPreparationStopsUnstartedReadsAndCannotPublishConfirmation() async {
        let started = expectation(description: "Preparation started")
        let provider = FakeBatchProvider(pausedPlanName: "one", onPlan: { started.fulfill() })
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        let task = Task { await installation.preview("one\ntwo", scope: .npm) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(installation.isPreparing)
        XCTAssertTrue(model.isBusy)
        installation.dismissPreview()
        await task.value
        XCTAssertFalse(installation.isPreparing)
        XCTAssertNil(installation.preview)
        XCTAssertFalse(model.isBusy)
        let planned = await provider.preparedNames()
        let executed = await provider.executedNames()
        XCTAssertEqual(planned, ["one"])
        XCTAssertTrue(executed.isEmpty)
    }

    func testSearchResolvesScopedRegistryBeforeRequestAndAdvertisesActualSource() async {
        let scoped = CatalogWebsites.url(host: "scope.fixture.invalid", path: "/")
        let initial = DiscoverNPMContext(environment: environment, registryURL: CatalogWebsites.npmRegistry)
        let dependencies = DiscoverSearchDependencies(homebrew: { _, _, _, _ in .init(packages: [], failedDetailCount: 0) }, npm: { query, context, _ in
            XCTAssertEqual(query, "@scope/one")
            XCTAssertEqual(context.registryURL, scoped)
            return [.init(identity: .init(name: query, environment: context.environment), version: "1.0.0", description: nil, websiteURL: nil, registryURL: context.registryURL)]
        }, resolveNPM: { query, context in
            XCTAssertEqual(try NPMRegistryClient.packageScope(query), "@scope")
            return .init(environment: context.environment, registryURL: scoped)
        })
        let search = DiscoverSearchModel(dependencies: dependencies, operationStore: OperationStore())
        await search.search("@scope/one", scope: .npm, context: .init(homebrewAvailable: true, npm: initial))
        XCTAssertEqual(search.resultContext?.npm?.registryURL, scoped)
        XCTAssertEqual(search.state, .available)
    }

    func testSingleScopedInstallRefusesSearchSourceMismatchBeforeAnyMutation() async {
        let scoped = CatalogWebsites.url(host: "scope.fixture.invalid", path: "/")
        let provider = FakeBatchProvider(registries: ["@scope/one": scoped])
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        let card = npmResult("@scope/one").card(homebrew: nil, node: model.node, activeIntent: nil, running: nil, canInstall: true)
        await installation.install(card, context: model.discoverContext)
        XCTAssertEqual(installation.error, .sourceMismatch)
        let executed = await provider.executedNames()
        XCTAssertTrue(executed.isEmpty)
        XCTAssertNil(installation.result)
    }

    func testDismissedOrChangedContextPreviewCannotInstall() async {
        for changeRegistry in [true, false] {
            let provider = FakeBatchProvider()
            let model = fixtureModel(provider)
            let installation = DiscoverInstallationModel(model: model)
            await installation.preview("one", scope: .npm)
            if changeRegistry { model.node = snapshot(registry: "https://other.fixture.invalid") }
            else { installation.dismissPreview() }
            await installation.confirmInstall()
            let names = await provider.executedNames()
            XCTAssertTrue(names.isEmpty)
            if changeRegistry { XCTAssertEqual(installation.error, .staleContext) }
        }
    }

    func testDuplicateDirectInstallDoesNotOverwritePausedAttemptFeedback() async {
        for pauseDuringPreparation in [true, false] {
            let started = expectation(description: "Direct install paused")
            let provider = FakeBatchProvider(pausedName: pauseDuringPreparation ? nil : "one", onPaused: { started.fulfill() },
                                             pausedPlanName: pauseDuringPreparation ? "one" : nil, onPlan: { started.fulfill() })
            let model = fixtureModel(provider)
            let installation = DiscoverInstallationModel(model: model)
            let context = model.discoverContext
            let card = npmResult("one").card(homebrew: nil, node: model.node, activeIntent: nil, running: nil, canInstall: true)
            let attempt = Task { await installation.install(card, context: context) }
            await fulfillment(of: [started], timeout: 3)
            await installation.install(card, context: context)
            XCTAssertNil(installation.error, "A duplicate must not publish an error for the active attempt")
            XCTAssertNil(installation.result)
            let names = await provider.preparedNames()
            XCTAssertEqual(names, pauseDuringPreparation ? ["one"] : ["one", "one"])
            let specs = await provider.executedSpecs()
            XCTAssertEqual(specs, pauseDuringPreparation ? [] : ["one@2.0.0"])
            attempt.cancel()
            await attempt.value
            XCTAssertFalse(model.isBusy)
        }
    }

    func testSingleCardInstallStartsDirectlyAndRefreshFailureKeepsResult() async throws {
        let provider = FakeBatchProvider(refreshFails: true)
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        let context = model.discoverContext
        let card = npmResult("one").card(homebrew: nil, node: model.node, activeIntent: nil, running: nil, canInstall: true)
        await installation.install(card, context: context)
        XCTAssertNil(installation.preview)
        let names = await provider.executedNames()
        XCTAssertEqual(names, ["one"])
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.succeeded])
        XCTAssertEqual(installation.result?.refreshStatus, .failed)
        XCTAssertTrue(model.nodeRefreshFailed)
        XCTAssertEqual(model.node?.summary.nodePath, environment.identifier)
    }

    func testInstallCancellationStopsUnstartedAndRetainsPartialResults() async {
        let started = expectation(description: "Second install started")
        let provider = FakeBatchProvider(pausedName: "two", onPaused: { started.fulfill() })
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        await installation.preview("one\ntwo\nthree", scope: .npm)
        let task = Task { await installation.confirmInstall() }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await task.value
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.succeeded, .cancelled, .cancelled])
        XCTAssertEqual(installation.result?.refreshStatus, .succeeded)
        let names = await provider.executedNames()
        XCTAssertEqual(names, ["one", "two"])
        XCTAssertFalse(model.isBusy)
    }

    func testDiscoverUsesSharedNativeSearchIntentInertCardsAndLocalizedConfirmation() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appending(path: "Features/Discover/DiscoverView.swift"), encoding: .utf8)
        let commands = try String(contentsOf: root.appending(path: "Features/AppCommands.swift"), encoding: .utf8)
        let library = try String(contentsOf: root.appending(path: "Features/Library/LibraryView.swift"), encoding: .utf8)
        for source in [view, library] { XCTAssertTrue(source.contains(".focusedSceneValue(\\.catalogSearchAction)")) }
        XCTAssertEqual(commands.components(separatedBy: ".keyboardShortcut(\"f\", modifiers: .command)").count, 2)
        XCTAssertTrue(view.contains("CatalogCardGrid("))
        let sheet = try String(contentsOf: root.appending(path: "Features/Discover/DiscoverBatchInstallSheet.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("preview.plan.items"))
        XCTAssertTrue(sheet.contains("DiscoverNPMDestinationView"))
        XCTAssertTrue(sheet.contains(".disabled(preview.plan.executableCount == 0)"))
        for forbidden in ["NavigationLink", "onTapGesture", "Process(", "plan sheet", "generate plan", "AsyncImage"] { XCTAssertFalse(view.contains(forbidden)) }
        for (language, expected) in [("en", "Installed"), ("zh-Hans", "已安装"), ("zh-Hant", "已安裝")] {
            var resource = BatchItemStatus.succeeded.discoverTitle
            resource.locale = Locale(identifier: language)
            XCTAssertEqual(String(localized: resource), expected)
        }
        for (language, expected) in [("en", "Ready to Install"), ("zh-Hans", "可安装"), ("zh-Hant", "可安裝")] {
            var resource = BatchPreparationStatus.ready.discoverTitle
            resource.locale = Locale(identifier: language)
            XCTAssertEqual(String(localized: resource), expected)
        }
    }

    private func npmResult(_ name: String) -> DiscoverResult {
        .npm(.init(identity: .init(name: name, environment: environment), version: "2.0.0", description: "Fixture", websiteURL: nil, registryURL: CatalogWebsites.npmRegistry))
    }

    private func snapshot(packages: [NodePackageRow] = [], registry: String = "https://registry.npmjs.org") -> NodeSnapshot {
        NodeSnapshot(summary: .init(nodePath: environment.identifier, npmPath: capabilityRoot.appending(path: ".nvm/versions/node/v22.0.0/bin/npm").path, nodeVersion: environment.nodeVersion, npmVersion: environment.npmVersion, nvmLoaded: true, globalPrefix: "/fixture", globalRoot: "/fixture/lib", registry: registry), configuration: .init(registry: registry, cache: "", prefix: "/fixture", userRegistry: "", projectRegistry: "", globalRegistry: ""), packages: packages, installations: NodeEnvironmentResolver(homeDirectory: capabilityRoot).installations(), managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil, packageEnvironment: environment)
    }

    private func fixtureModel(_ provider: FakeBatchProvider) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarDiscoverUnused-\(UUID())")
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root), nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: root)), shellClient: ShellManagerClient(runner: runner), environmentResolver: .init(homeDirectory: root))
        let model = AppModel(service: service, operationStore: OperationStore(), batchProvider: provider)
        model.node = snapshot()
        model.homebrew = HomebrewStatus(executablePath: "/fixture/brew", version: "5.0.0", managerAvailable: true, snapshot: nil)
        return model
    }
}

private actor DiscoverSearchFixture {
    private var count = 0
    private var limits: [Int] = []
    nonisolated var dependencies: DiscoverSearchDependencies {
        .init(homebrew: { query, kind, limit, _ in .init(packages: try await self.search(query, kind: kind, limit: limit), failedDetailCount: 0) }, npm: { _, _, _ in [] })
    }
    func search(_ query: String, kind: HomebrewPackageKind, limit: Int) throws -> [HomebrewPackage] {
        count += 1
        limits.append(limit)
        if query == "failed" { throw CatalogSourceError.invalidResponse }
        if query == "empty" { return [] }
        if query == "many" { return (0...100).map { Self.package("item\($0)", kind: kind) } }
        return [Self.package(query, kind: kind)]
    }
    nonisolated static func package(_ name: String, kind: HomebrewPackageKind) -> HomebrewPackage {
        HomebrewPackage(identity: .init(name: name, kind: kind), displayName: name, description: "Fixture", homepage: nil,
                                installedVersions: [], currentVersion: "1.0.0", tap: nil, dependencies: [], pinned: false,
                                deprecated: false, disabled: false, artifacts: [])
    }
    func requestCount() -> Int { count }
    func requestLimits() -> [Int] { limits }
}

private actor DeferredDiscoverSearch {
    let onStart: @Sendable () -> Void
    var continuation: CheckedContinuation<Void, Never>?
    init(onStart: @escaping @Sendable () -> Void) { self.onStart = onStart }
    nonisolated var dependencies: DiscoverSearchDependencies {
        .init(homebrew: { query, kind, _, _ in .init(packages: await self.search(query, kind: kind), failedDetailCount: 0) }, npm: { _, _, _ in [] })
    }
    func search(_ query: String, kind: HomebrewPackageKind) async -> [HomebrewPackage] {
        if query == "old" {
            await withCheckedContinuation { continuation in self.continuation = continuation; onStart() }
        }
        return [DiscoverSearchFixture.package(query, kind: kind)]
    }
    func finishOld() { continuation?.resume(); continuation = nil }
}

private actor DetailEnrichmentGate {
    let capacity: Int
    let first: @Sendable () -> Void
    let next: @Sendable () -> Void
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var released = false
    private(set) var startedCount = 0
    private(set) var active = 0
    private(set) var peak = 0

    init(capacity: Int, first: @escaping @Sendable () -> Void, next: @escaping @Sendable () -> Void) {
        self.capacity = capacity
        self.first = first
        self.next = next
    }

    func load(_ identity: HomebrewPackageIdentity) async -> HomebrewPackage {
        startedCount += 1
        active += 1
        peak = max(peak, active)
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { pending[identity.name] = continuation }
            if startedCount <= capacity { first() } else { next() }
        }
        active -= 1
        return DiscoverSearchFixture.package(identity.name, kind: identity.kind)
    }

    func release(_ name: String) { pending.removeValue(forKey: name)?.resume() }
    func releaseAll() {
        released = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
