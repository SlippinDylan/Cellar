import XCTest
@testable import Cellar

@MainActor
final class DiscoverTests: XCTestCase {
    private let environment = NodeEnvironmentContext(identifier: "/fixture/node", nodeVersion: "v22.0.0", npmVersion: "10.0.0")

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
        XCTAssertTrue(store.hasActiveOperations)
        let replacement = Task { await model.search("new", scope: .homebrewCask, context: context) }
        await Task.yield()
        await fake.finishOld()
        await first.value
        await replacement.value
        XCTAssertEqual(model.results.first?.identity, .homebrew(.init(name: "new", kind: .cask)))
        XCTAssertEqual(model.state, .available)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testInvalidationAndUserCancelKeepTaskRegisteredUntilSearchCleanup() async {
        for invalidate in [false, true] {
            let started = expectation(description: "Search started")
            let fake = DeferredDiscoverSearch(onStart: { started.fulfill() })
            let store = OperationStore()
            let model = DiscoverSearchModel(dependencies: fake.dependencies, operationStore: store)
            let task = Task { await model.search("old", scope: .homebrewFormula, context: .init(homebrewAvailable: true, npm: nil)) }
            await fulfillment(of: [started], timeout: 3)
            if invalidate { model.invalidate() } else { store.cancelActiveTask() }
            XCTAssertTrue(store.hasActiveOperations)
            await fake.finishOld()
            await task.value
            XCTAssertEqual(model.state, invalidate ? .idle : .cancelled)
            XCTAssertTrue(model.results.isEmpty)
            XCTAssertFalse(store.hasActiveOperations)
            XCTAssertNil(store.activeTask)
        }
    }

    func testMenuCancelAlsoWithdrawsReplacementWaitingForCancelledSearch() async {
        let started = expectation(description: "First query started")
        let fake = DeferredDiscoverSearch(onStart: { started.fulfill() })
        let store = OperationStore()
        let model = DiscoverSearchModel(dependencies: fake.dependencies, operationStore: store)
        let context = DiscoverContext(homebrewAvailable: true, npm: nil)
        let old = Task { await model.search("old", scope: .homebrewFormula, context: context) }
        await fulfillment(of: [started], timeout: 3)
        let replacement = Task { await model.search("new", scope: .homebrewCask, context: context) }
        await Task.yield()
        store.cancelActiveTask()
        await fake.finishOld()
        await old.value
        await replacement.value
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testRegistrySearchUsesDisplayedRegistryAndExactNodeEnvironment() async throws {
        let transport = FakeCatalogTransport(body: Data(#"{"objects":[{"package":{"name":"one","version":"2.0.0","description":"Registry fixture"}}],"total":1}"#.utf8))
        let registry = try XCTUnwrap(URL(string: "https://registry.fixture.invalid/custom"))
        let context = DiscoverNPMContext(environment: environment, registryURL: registry)
        let dependencies = DiscoverSearchDependencies(homebrew: { _, _, _ in [] }, npm: { query, target, limit in
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
            XCTAssertNil(card.primaryAction)
            XCTAssertEqual(card.nodeEnvironment, environment)
        }
        XCTAssertEqual(npmResult("missing").card(homebrew: nil, node: node, activeIntent: nil, running: nil, canInstall: true).primaryAction, .install)
        let package = DiscoverSearchFixture.package("one", kind: .formula)
        let formula = DiscoverResult.homebrew(package).card(homebrew: nil, node: nil, activeIntent: nil, running: nil, canInstall: true)
        XCTAssertEqual(formula.websiteURL?.absoluteString, "https://formulae.brew.sh/formula/one")
        XCTAssertEqual(formula.description, "Fixture")
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
        await provider.changeDestination()
        await installation.confirmInstall()
        let plannedAfter = await provider.preparedNames()
        let executed = await provider.executedNames()
        XCTAssertEqual(plannedAfter, ["one", "two"])
        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.failed, .failed])
    }

    func testLaterItemCannotAdoptDestinationChangedByEarlierItemAfterConfirmation() async {
        let provider = FakeBatchProvider(changeDestinationAfterName: "one")
        let model = fixtureModel(provider)
        let installation = DiscoverInstallationModel(model: model)
        await installation.preview("one\ntwo", scope: .npm)
        XCTAssertEqual(installation.preview?.plan.npmBindings.map(\.destination.globalRoot), ["/fake", "/fake"])
        await installation.confirmInstall()
        XCTAssertEqual(installation.result?.outcome.itemOutcomes.map(\.status), [.succeeded, .failed])
        let planned = await provider.preparedNames()
        let executed = await provider.executedNames()
        XCTAssertEqual(planned, ["one", "two"])
        XCTAssertEqual(executed, ["one"])
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
        let dependencies = DiscoverSearchDependencies(homebrew: { _, _, _ in [] }, npm: { query, context, _ in
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
        model.operationStore.cancelActiveTask()
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
        NodeSnapshot(summary: .init(nodePath: environment.identifier, npmPath: "/fixture/npm", nodeVersion: environment.nodeVersion, npmVersion: environment.npmVersion, nvmLoaded: true, globalPrefix: "/fixture", globalRoot: "/fixture/lib", registry: registry), configuration: .init(registry: registry, cache: "", prefix: "/fixture", userRegistry: "", projectRegistry: "", globalRegistry: ""), packages: packages, installations: [], managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil)
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
        .init(homebrew: { query, kind, limit in try await self.search(query, kind: kind, limit: limit) }, npm: { _, _, _ in [] })
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
        .init(homebrew: { query, kind, _ in await self.search(query, kind: kind) }, npm: { _, _, _ in [] })
    }
    func search(_ query: String, kind: HomebrewPackageKind) async -> [HomebrewPackage] {
        if query == "old" {
            await withCheckedContinuation { continuation in self.continuation = continuation; onStart() }
        }
        return [DiscoverSearchFixture.package(query, kind: kind)]
    }
    func finishOld() { continuation?.resume(); continuation = nil }
}
