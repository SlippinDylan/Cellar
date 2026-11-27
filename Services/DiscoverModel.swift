import Foundation

struct DiscoverSearchDependencies: Sendable {
    let homebrew: @Sendable (String, HomebrewPackageKind, Int, Int) async throws -> HomebrewDiscoveryResult
    let npm: @Sendable (String, DiscoverNPMContext, Int) async throws -> [NPMCatalogResult]
    let resolveNPM: @Sendable (String, DiscoverNPMContext) async throws -> DiscoverNPMContext

    init(homebrew: @escaping @Sendable (String, HomebrewPackageKind, Int, Int) async throws -> HomebrewDiscoveryResult,
         npm: @escaping @Sendable (String, DiscoverNPMContext, Int) async throws -> [NPMCatalogResult],
         resolveNPM: @escaping @Sendable (String, DiscoverNPMContext) async throws -> DiscoverNPMContext = { _, context in context }) {
        self.homebrew = homebrew
        self.npm = npm
        self.resolveNPM = resolveNPM
    }

    static func live(service: SystemProbeService) -> Self {
        let http = CatalogHTTPClient()
        return Self(homebrew: { try await service.discoverHomebrew($0, kind: $1, limit: $2, maximumConcurrentDetails: $3) },
                    npm: { query, context, limit in
            try await NPMRegistryClient(registryURL: context.registryURL, http: http).search(query, environment: context.environment, limit: limit)
        }, resolveNPM: { query, context in
            .init(environment: context.environment, registryURL: try await service.effectiveNPMRegistry(query, environment: context.environment))
        })
    }
}

@MainActor
final class DiscoverSearchModel: ObservableObject {
    @Published private(set) var state = DiscoverSearchState.idle
    @Published private(set) var results: [DiscoverResult] = []
    @Published private(set) var resultContext: DiscoverContext?
    @Published private(set) var partialScopes: [CatalogProviderScope] = []
    @Published private(set) var unavailableScopes: [CatalogProviderScope] = []
    @Published private(set) var cachedResultsByScope: [CatalogProviderScope: [DiscoverResult]] = [:]
    @Published private(set) var loadingScopes: Set<CatalogProviderScope> = []
    @Published private(set) var completedScopes: Set<CatalogProviderScope> = []
    @Published private(set) var unavailableByScope: Set<CatalogProviderScope> = []
    @Published private(set) var partialByScope: Set<CatalogProviderScope> = []
    @Published private(set) var lastQuery = ""
    private let dependencies: DiscoverSearchDependencies
    private let operationStore: OperationStore
    private var latestRequest: UUID?
    private var owner: (id: UUID, task: Task<Void, Never>)?

    init(dependencies: DiscoverSearchDependencies, operationStore: OperationStore) {
        self.dependencies = dependencies
        self.operationStore = operationStore
    }

    func invalidate() {
        latestRequest = nil
        owner?.task.cancel()
        state = .idle
        results = []
        resultContext = nil
        unavailableScopes = []
        partialScopes = []
        cachedResultsByScope = [:]
        loadingScopes = []
        completedScopes = []
        unavailableByScope = []
        partialByScope = []
        lastQuery = ""
    }

    func results(for scope: DiscoverSearchScope) -> [DiscoverResult] {
        switch scope {
        case .all:
            CatalogProviderScope.allCases.flatMap { cachedResultsByScope[$0, default: []] }
        case .homebrewFormula:
            cachedResultsByScope[.homebrewFormula, default: []]
        case .homebrewCask:
            cachedResultsByScope[.homebrewCask, default: []]
        case .npm:
            cachedResultsByScope[.npm, default: []]
        }
    }

    func unavailableScopes(for scope: DiscoverSearchScope) -> [CatalogProviderScope] {
        let targets = providerScopes(for: scope)
        return targets.filter { unavailableByScope.contains($0) }
    }

    func partialScopes(for scope: DiscoverSearchScope) -> [CatalogProviderScope] {
        let targets = providerScopes(for: scope)
        return targets.filter { partialByScope.contains($0) }
    }

    func state(for scope: DiscoverSearchScope, context: DiscoverContext) -> DiscoverSearchState {
        if lastQuery.isEmpty {
            return state
        }
        if let guidance = Self.guidance(scope, context: context) {
            return guidance
        }
        let visible = results(for: scope)
        if !visible.isEmpty {
            return .available
        }
        let targets = providerScopes(for: scope)
        if targets.contains(where: { loadingScopes.contains($0) }) {
            return .loading
        }
        if state == .cancelled {
            return .cancelled
        }
        let allUnavailable = !targets.isEmpty && targets.allSatisfy { unavailableByScope.contains($0) }
        if allUnavailable {
            return .failed
        }
        if targets.allSatisfy({ completedScopes.contains($0) }) {
            return .empty
        }
        return state
    }

    func searchGlobally(_ query: String, preferredScope: DiscoverSearchScope, context: DiscoverContext, limit: Int = 50) async {
        let request = UUID()
        latestRequest = request
        results = []
        resultContext = nil
        unavailableScopes = []
        partialScopes = []
        cachedResultsByScope = [:]
        loadingScopes = []
        completedScopes = []
        unavailableByScope = []
        partialByScope = []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = term
        if let previous = owner {
            previous.task.cancel()
            await previous.task.value
        }
        guard latestRequest == request, !Task.isCancelled else { return }
        guard !term.isEmpty else { state = .idle; return }
        guard term.utf8.count <= 512, (1...100).contains(limit) else { state = .failed; return }
        if !context.homebrewAvailable && context.npm == nil {
            state = Self.guidance(preferredScope, context: context) ?? .homebrewRequired
            return
        }
        state = .loading
        let searchID = UUID()
        let task = Task { await self.runGlobal(term, preferredScope: preferredScope, context: context, limit: limit, request: request) }
        let readOnlyID = operationStore.registerReadOnlyOperation(
            cancel: { task.cancel() },
            awaitCompletion: { await task.value }
        )
        owner = (searchID, task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        operationStore.unregisterReadOnlyOperation(readOnlyID)
        if owner?.id == searchID { owner = nil }
    }

    private func providerScopes(for scope: DiscoverSearchScope) -> [CatalogProviderScope] {
        switch scope {
        case .all: CatalogProviderScope.allCases
        case .homebrewFormula: [.homebrewFormula]
        case .homebrewCask: [.homebrewCask]
        case .npm: [.npm]
        }
    }

    private func runGlobal(_ query: String, preferredScope: DiscoverSearchScope, context: DiscoverContext, limit: Int,
                           request: UUID) async {
        let primaryScopes = providerScopes(for: preferredScope)
        let secondaryScopes = CatalogProviderScope.allCases.filter { !primaryScopes.contains($0) }
        loadingScopes = Set(CatalogProviderScope.allCases)
        resultContext = context

        do {
            // Query the active tab first so the user sees immediate results, then fetch remaining scopes in the background.
            try await fetchScopes(primaryScopes, query: query, context: context, limit: limit, request: request)
            if !secondaryScopes.isEmpty {
                try await fetchScopes(secondaryScopes, query: query, context: context, limit: limit, request: request)
            }
            guard latestRequest == request, !Task.isCancelled else { return }
            let allResults = results(for: .all)
            results = allResults
            unavailableScopes = CatalogProviderScope.allCases.filter { unavailableByScope.contains($0) }
            partialScopes = CatalogProviderScope.allCases.filter { partialByScope.contains($0) }
            let allUnavailable = unavailableByScope.count == CatalogProviderScope.allCases.count
            state = allResults.isEmpty ? (allUnavailable ? .failed : .empty) : .available
        } catch {
            guard latestRequest == request else { return }
            loadingScopes = []
            state = error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
        }
    }

    private func fetchScopes(_ scopes: [CatalogProviderScope], query: String, context: DiscoverContext, limit: Int,
                             request: UUID) async throws {
        guard !scopes.isEmpty else { return }
        let dependencies = dependencies
        let homebrewConcurrency = scopes.filter { $0 != .npm }.count > 1 ? 2 : 4
        try await withThrowingTaskGroup(of: (CatalogProviderScope, [DiscoverResult], DiscoverNPMContext?, Bool, Bool).self) { group in
            for scope in scopes {
                group.addTask {
                    do {
                        switch scope {
                        case .homebrewFormula, .homebrewCask:
                            guard context.homebrewAvailable else { return (scope, [], nil, true, false) }
                            let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
                            let discovery = try await dependencies.homebrew(query, kind, limit, homebrewConcurrency)
                            return (scope, discovery.packages.prefix(limit).map(DiscoverResult.homebrew), nil,
                                    discovery.isUnavailable, !discovery.isUnavailable && discovery.failedDetailCount > 0)
                        case .npm:
                            guard let base = context.npm else { return (scope, [], nil, true, false) }
                            let npm = try await dependencies.resolveNPM(query, base)
                            let packages = try await dependencies.npm(query, npm, limit)
                            return (scope, packages.prefix(limit).map(DiscoverResult.npm), npm, false, false)
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        return (scope, [], nil, true, false)
                    }
                }
            }
            for try await (scope, packages, npm, failed, incomplete) in group {
                try Task.checkCancellation()
                guard latestRequest == request, !Task.isCancelled else { throw CancellationError() }
                cachedResultsByScope[scope] = packages
                loadingScopes.remove(scope)
                completedScopes.insert(scope)
                if failed { unavailableByScope.insert(scope) }
                if incomplete { partialByScope.insert(scope) }
                if let npm {
                    resultContext = .init(homebrewAvailable: context.homebrewAvailable, npm: npm, nodeAvailable: true, registryAvailable: true)
                }
                results = results(for: .all)
                unavailableScopes = CatalogProviderScope.allCases.filter { unavailableByScope.contains($0) }
                partialScopes = CatalogProviderScope.allCases.filter { partialByScope.contains($0) }
                if !results.isEmpty {
                    state = .available
                }
            }
        }
    }

    func search(_ query: String, scope: DiscoverSearchScope, context: DiscoverContext, limit: Int = 50) async {
        let request = UUID()
        latestRequest = request
        results = []
        resultContext = nil
        unavailableScopes = []
        partialScopes = []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previous = owner {
            previous.task.cancel()
            await previous.task.value
        }
        guard latestRequest == request, !Task.isCancelled else { return }
        guard !term.isEmpty else { state = .idle; return }
        guard term.utf8.count <= 512, (1...100).contains(limit) else { state = .failed; return }
        if let guidance = Self.guidance(scope, context: context) { state = guidance; return }
        guard !operationStore.hasActiveOperations else { state = .busy; return }
        state = .loading
        let searchID = UUID()
        let task = Task { await self.run(term, scope: scope, context: context, limit: limit, request: request) }
        let readOnlyID = operationStore.registerReadOnlyOperation(
            cancel: { task.cancel() },
            awaitCompletion: { await task.value }
        )
        owner = (searchID, task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        operationStore.unregisterReadOnlyOperation(readOnlyID)
        if owner?.id == searchID { owner = nil }
    }

    static func guidance(_ scope: DiscoverSearchScope, context: DiscoverContext) -> DiscoverSearchState? {
        switch scope {
        case .all: context.homebrewAvailable || context.npm != nil ? nil : .homebrewRequired
        case .homebrewFormula, .homebrewCask: context.homebrewAvailable ? nil : .homebrewRequired
        case .npm: context.npm == nil ? (context.nodeAvailable && !context.registryAvailable ? .registryRequired : .nodeRequired) : nil
        }
    }

    private func run(_ query: String, scope: DiscoverSearchScope, context: DiscoverContext, limit: Int,
                     request: UUID) async {
        do {
            let values: [DiscoverResult]
            var effectiveContext = context
            var unavailable: [CatalogProviderScope] = []
            var partial: [CatalogProviderScope] = []
            switch scope {
            case .all:
                let merged = try await self.searchAll(query, context: context, limit: limit)
                values = merged.results
                effectiveContext = merged.context
                unavailable = merged.unavailable
                partial = merged.partial
            case .homebrewFormula, .homebrewCask:
                let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
                let discovery = try await self.dependencies.homebrew(query, kind, limit, 4)
                values = discovery.packages.prefix(limit).map(DiscoverResult.homebrew)
                let source: CatalogProviderScope = kind == .formula ? .homebrewFormula : .homebrewCask
                if discovery.isUnavailable { unavailable = [source] }
                else if discovery.failedDetailCount > 0 { partial = [source] }
            case .npm:
                guard let base = context.npm else { preconditionFailure("npm search requires a validated context") }
                let npm = try await self.dependencies.resolveNPM(query, base)
                effectiveContext = DiscoverContext(homebrewAvailable: context.homebrewAvailable, npm: npm, nodeAvailable: true, registryAvailable: true)
                guard self.latestRequest == request else { throw CancellationError() }
                self.resultContext = effectiveContext
                values = try await self.dependencies.npm(query, npm, limit).prefix(limit).map(DiscoverResult.npm)
            }
            try Task.checkCancellation()
            guard latestRequest == request, !Task.isCancelled else { return }
            self.results = values
            resultContext = effectiveContext
            unavailableScopes = unavailable
            partialScopes = partial
            let allUnavailable = scope == .all ? unavailable.count == CatalogProviderScope.allCases.count : !unavailable.isEmpty
            state = values.isEmpty ? (allUnavailable ? .failed : .empty) : .available
        } catch {
            guard latestRequest == request else { return }
            state = error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
        }
    }

    private func searchAll(_ query: String, context: DiscoverContext, limit: Int) async throws
        -> (results: [DiscoverResult], context: DiscoverContext, unavailable: [CatalogProviderScope], partial: [CatalogProviderScope]) {
        let dependencies = dependencies
        return try await withThrowingTaskGroup(of: (CatalogProviderScope, [DiscoverResult], DiscoverNPMContext?, Bool, Bool).self) { group in
            for scope in CatalogProviderScope.allCases {
                group.addTask {
                    do {
                        switch scope {
                        case .homebrewFormula, .homebrewCask:
                            guard context.homebrewAvailable else { return (scope, [], nil, true, false) }
                            let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
                            // All runs both Homebrew categories concurrently, sharing a total budget of four.
                            let discovery = try await dependencies.homebrew(query, kind, limit, 2)
                            return (scope, discovery.packages.prefix(limit).map(DiscoverResult.homebrew), nil,
                                    discovery.isUnavailable, !discovery.isUnavailable && discovery.failedDetailCount > 0)
                        case .npm:
                            guard let base = context.npm else { return (scope, [], nil, true, false) }
                            let npm = try await dependencies.resolveNPM(query, base)
                            let packages = try await dependencies.npm(query, npm, limit)
                            return (scope, packages.prefix(limit).map(DiscoverResult.npm), npm, false, false)
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        return (scope, [], nil, true, false)
                    }
                }
            }
            var results: [CatalogProviderScope: [DiscoverResult]] = [:]
            var unavailable: [CatalogProviderScope] = []
            var partial: [CatalogProviderScope] = []
            var effectiveContext = context
            for try await (scope, packages, npm, failed, incomplete) in group {
                results[scope] = packages
                if failed { unavailable.append(scope) }
                if incomplete { partial.append(scope) }
                if let npm { effectiveContext = .init(homebrewAvailable: context.homebrewAvailable, npm: npm, nodeAvailable: true, registryAvailable: true) }
            }
            try Task.checkCancellation()
            return (CatalogProviderScope.allCases.flatMap { results[$0, default: []] }, effectiveContext,
                    CatalogProviderScope.allCases.filter { unavailable.contains($0) },
                    CatalogProviderScope.allCases.filter { partial.contains($0) })
        }
    }
}

@MainActor
final class DiscoverInstallationModel: ObservableObject {
    @Published private(set) var preview: DiscoverInstallPreview?
    @Published private(set) var result: BatchExecutionResult?
    @Published private(set) var error: DiscoverInputError?
    @Published private(set) var isPreparing = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var queuedItems: [BatchItem] = []
    @Published private(set) var activeItem: BatchItem?
    private let model: AppModel
    private var previewRequest: UUID?
    private var preparationTask: Task<BatchPlan, Error>?
    private var pendingQueue: [(card: CatalogCardState, context: DiscoverContext)] = []
    private var queueTask: Task<Void, Never>?
    private var stopWaitingForBusy = false

    var isQueueActive: Bool { activeItem != nil || !queuedItems.isEmpty }

    init(model: AppModel) { self.model = model }

    func cancelPendingQueue() {
        pendingQueue.removeAll()
        queuedItems.removeAll()
        stopWaitingForBusy = true
    }

    func enqueueInstall(_ card: CatalogCardState, context: DiscoverContext) {
        guard card.primaryAction == .install, !isPreparing, preview == nil else { return }
        let item = card.batchItem
        guard activeItem != item, !queuedItems.contains(item) else { return }
        stopWaitingForBusy = false
        pendingQueue.append((card, context))
        queuedItems.append(item)
        if queueTask == nil {
            queueTask = Task { await processQueue() }
        }
    }

    private func processQueue() async {
        defer {
            activeItem = nil
            queueTask = nil
        }
        while !pendingQueue.isEmpty && !Task.isCancelled {
            while model.isBusy && !stopWaitingForBusy && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !pendingQueue.isEmpty, !stopWaitingForBusy, !Task.isCancelled else { break }
            let next = pendingQueue.removeFirst()
            let item = next.card.batchItem
            queuedItems.removeAll { $0 == item }
            activeItem = item
            error = nil
            result = nil
            await install(next.card, context: next.context)
            var failureLine: String?
            if let err = error {
                failureLine = "\(next.card.displayName): \(String(localized: err.discoverMessage))"
            } else if let res = result, res.outcome.status != .succeeded {
                let reason = res.outcome.itemOutcomes.first?.reason?.message
                if let reason {
                    failureLine = "\(next.card.displayName): \(String(localized: reason))"
                } else {
                    failureLine = "\(next.card.displayName): \(String(localized: res.outcome.status.libraryTitle))"
                }
            }
            if let failureLine {
                model.recordQueuedBatchFailure(failureLine)
            } else if let res = result, res.refreshStatus == .failed {
                model.recordQueuedBatchFailure("\(next.card.displayName): \(String(localized: "Installation finished, but the environment could not be refreshed. Use Refresh to check the current state."))")
            }
            activeItem = nil
        }
        queuedItems.removeAll()
    }

    func preview(_ input: String, scope: CatalogProviderScope) async {
        guard !Task.isCancelled, !isSubmitting, !isPreparing, !model.isBusy else { return }
        let request = UUID()
        previewRequest = request
        preview = nil
        error = nil
        isPreparing = true
        defer {
            if previewRequest == request { isPreparing = false; preparationTask = nil }
        }
        do {
            if scope != .npm, !model.discoverContext.homebrewAvailable { throw DiscoverInputError.missingContext }
            if scope == .npm, model.nodeRefreshFailed { throw DiscoverInputError.missingContext }
            let context = model.discoverContext
            let npm = scope == .npm ? context.npm : nil
            let intent = try DiscoverBatchInput.intent(input, scope: scope, npm: npm)
            let task = Task { try await self.model.prepareBatch(intent) }
            preparationTask = task
            let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard previewRequest == request, !Task.isCancelled else { return }
            try checkBindings(plan)
            preview = DiscoverInstallPreview(plan: plan, context: context)
        } catch is CancellationError { return }
        catch let error as DiscoverInputError { self.error = error }
        catch let error as BatchOperationError where error == .reconciliationUnavailable {
            if previewRequest == request { self.error = .staleContext }
        }
        catch { if previewRequest == request { self.error = .installationFailed } }
    }

    func dismissPreview() {
        previewRequest = nil
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
        preview = nil
        error = nil
    }

    func dismissResult() {
        result = nil
    }

    func confirmInstall() async {
        guard !isSubmitting, !model.isBusy, let preview else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        self.preview = nil
        // The confirmation consumes only the plans and destinations already shown.
        let currentContextMatches = switch preview.intent.scope {
        case .npm: preview.context.npm == model.discoverContext.npm
        case .homebrew: true
        case .nodeRuntime: false
        }
        guard valid(preview.intent), currentContextMatches
        else { error = .staleContext; return }
        await execute(preview.plan)
    }

    func install(_ card: CatalogCardState, context: DiscoverContext) async {
        // A duplicate cannot replace the active attempt's feedback or prepared plan.
        guard !isSubmitting, !isPreparing, !model.isBusy, preview == nil else { return }
        guard card.primaryAction == .install, card.progress == .idle,
              let intent = BatchIntent(operation: .install, items: [card.batchItem]) else { return }
        guard valid(intent) else { error = .staleContext; return }
        isSubmitting = true
        error = nil
        result = nil
        defer { isSubmitting = false }
        do {
            let plan = try await model.prepareBatch(intent)
            try checkBindings(plan)
            if let npm = context.npm, !plan.npmBindings.allSatisfy({ $0.registryURL == npm.registryURL }) { throw DiscoverInputError.sourceMismatch }
            await execute(plan)
        } catch is CancellationError {
            // Preparation cancellation has no write outcome to report.
        } catch let error as DiscoverInputError { self.error = error }
        catch let error as BatchOperationError where error == .reconciliationUnavailable { self.error = .staleContext }
        catch { self.error = .installationFailed }
    }

    private func valid(_ intent: BatchIntent) -> Bool {
        switch intent.scope {
        case .homebrew: return model.discoverContext.homebrewAvailable
        case .npm(let environment): return !model.nodeRefreshFailed && model.discoverContext.npm?.environment == environment
        case .nodeRuntime: return false
        }
    }

    private func checkBindings(_ plan: BatchPlan) throws {
        if let first = plan.npmBindings.first {
            guard plan.npmBindings.allSatisfy({ $0.registryURL == first.registryURL }) else { throw DiscoverInputError.mixedRegistries }
            guard plan.npmBindings.allSatisfy({ $0.destination == first.destination }) else { throw DiscoverInputError.staleContext }
        }
    }

    private func execute(_ plan: BatchPlan) async {
        error = nil
        result = nil
        do {
            guard valid(plan.intent), !Task.isCancelled else { throw DiscoverInputError.staleContext }
            result = try await model.executeBatch(plan)
        } catch is CancellationError { return }
        catch let error as DiscoverInputError { self.error = error }
        catch let error as BatchOperationError where error == .planUnavailable || error == .reconciliationUnavailable {
            self.error = .staleContext
        }
        catch { self.error = .installationFailed }
    }
}

extension AppModel {
    var discoverContext: DiscoverContext {
        let registry = node.flatMap { SourceConfiguration.registryURL($0.summary.registry) }
        let npm: DiscoverNPMContext?
        if let environment = nodePackageEnvironment, let registry {
            npm = DiscoverNPMContext(environment: environment, registryURL: registry)
        } else { npm = nil }
        return DiscoverContext(homebrewAvailable: homebrew?.executablePath != nil && canMutatePackages(in: .homebrew(.formula)), npm: npm,
                               nodeAvailable: !nodeRefreshFailed && node != nil && node?.summary.nodePath.isEmpty == false && node?.summary.npmPath.isEmpty == false,
                               registryAvailable: registry != nil)
    }
}
