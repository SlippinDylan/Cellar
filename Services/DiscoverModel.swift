import Foundation

struct DiscoverSearchDependencies: Sendable {
    let homebrew: @Sendable (String, HomebrewPackageKind, Int) async throws -> [HomebrewPackage]
    let npm: @Sendable (String, DiscoverNPMContext, Int) async throws -> [NPMCatalogResult]
    let resolveNPM: @Sendable (String, DiscoverNPMContext) async throws -> DiscoverNPMContext

    init(homebrew: @escaping @Sendable (String, HomebrewPackageKind, Int) async throws -> [HomebrewPackage],
         npm: @escaping @Sendable (String, DiscoverNPMContext, Int) async throws -> [NPMCatalogResult],
         resolveNPM: @escaping @Sendable (String, DiscoverNPMContext) async throws -> DiscoverNPMContext = { _, context in context }) {
        self.homebrew = homebrew
        self.npm = npm
        self.resolveNPM = resolveNPM
    }

    static func live(service: SystemProbeService) -> Self {
        let http = CatalogHTTPClient()
        return Self(homebrew: { try await service.discoverHomebrew($0, kind: $1, limit: $2) },
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
    @Published private(set) var unavailableScopes: [CatalogProviderScope] = []
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
    }

    func search(_ query: String, scope: DiscoverSearchScope, context: DiscoverContext, limit: Int = 50) async {
        let request = UUID()
        latestRequest = request
        results = []
        resultContext = nil
        unavailableScopes = []
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
        let activityScope: ActivityScope? = switch scope {
        case .all: nil
        case .homebrewFormula: .homebrew(.formula)
        case .homebrewCask: .homebrew(.cask)
        case .npm:
            if let npm = context.npm { .npm(npm.environment) }
            else { preconditionFailure("npm search requires a validated context") }
        }
        let operationID = operationStore.begin(context: .init(operation: .search, scope: activityScope, targets: [], stage: .checking))
        let task = Task { await self.run(term, scope: scope, context: context, limit: limit, request: request, operationID: operationID) }
        owner = (operationID, task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if owner?.id == operationID { owner = nil }
    }

    static func guidance(_ scope: DiscoverSearchScope, context: DiscoverContext) -> DiscoverSearchState? {
        switch scope {
        case .all: context.homebrewAvailable || context.npm != nil ? nil : .homebrewRequired
        case .homebrewFormula, .homebrewCask: context.homebrewAvailable ? nil : .homebrewRequired
        case .npm: context.npm == nil ? (context.nodeAvailable ? .registryRequired : .nodeRequired) : nil
        }
    }

    private func run(_ query: String, scope: DiscoverSearchScope, context: DiscoverContext, limit: Int,
                     request: UUID, operationID: UUID) async {
        defer { operationStore.end(operationID) }
        do {
            let (results, resolvedContext, unavailable) = try await operationStore.performCancellable(operationID: operationID) {
                let values: [DiscoverResult]
                var effectiveContext = context
                var unavailable: [CatalogProviderScope] = []
                switch scope {
                case .all:
                    let merged = try await self.searchAll(query, context: context, limit: limit)
                    values = merged.results
                    effectiveContext = merged.context
                    unavailable = merged.unavailable
                case .homebrewFormula, .homebrewCask:
                    let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
                    values = try await self.dependencies.homebrew(query, kind, limit).prefix(limit).map(DiscoverResult.homebrew)
                case .npm:
                    guard let base = context.npm else { preconditionFailure("npm search requires a validated context") }
                    let npm = try await self.dependencies.resolveNPM(query, base)
                    effectiveContext = DiscoverContext(homebrewAvailable: context.homebrewAvailable, npm: npm, nodeAvailable: true)
                    guard self.latestRequest == request else { throw CancellationError() }
                    self.resultContext = effectiveContext
                    values = try await self.dependencies.npm(query, npm, limit).prefix(limit).map(DiscoverResult.npm)
                }
                try Task.checkCancellation()
                return (values, effectiveContext, unavailable)
            }
            guard latestRequest == request, !Task.isCancelled else { return }
            self.results = results
            resultContext = resolvedContext
            unavailableScopes = unavailable
            state = results.isEmpty ? (unavailable.isEmpty ? .empty : .failed) : .available
        } catch {
            guard latestRequest == request else { return }
            state = error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
        }
    }

    private func searchAll(_ query: String, context: DiscoverContext, limit: Int) async throws
        -> (results: [DiscoverResult], context: DiscoverContext, unavailable: [CatalogProviderScope]) {
        let dependencies = dependencies
        return try await withThrowingTaskGroup(of: (CatalogProviderScope, [DiscoverResult], DiscoverNPMContext?, Bool).self) { group in
            for scope in CatalogProviderScope.allCases {
                group.addTask {
                    do {
                        switch scope {
                        case .homebrewFormula, .homebrewCask:
                            guard context.homebrewAvailable else { return (scope, [], nil, true) }
                            let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
                            let packages = try await dependencies.homebrew(query, kind, limit)
                            return (scope, packages.prefix(limit).map(DiscoverResult.homebrew), nil, false)
                        case .npm:
                            guard let base = context.npm else { return (scope, [], nil, true) }
                            let npm = try await dependencies.resolveNPM(query, base)
                            let packages = try await dependencies.npm(query, npm, limit)
                            return (scope, packages.prefix(limit).map(DiscoverResult.npm), npm, false)
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            throw CancellationError()
                        }
                        return (scope, [], nil, true)
                    }
                }
            }
            var results: [CatalogProviderScope: [DiscoverResult]] = [:]
            var unavailable: [CatalogProviderScope] = []
            var effectiveContext = context
            for try await (scope, packages, npm, failed) in group {
                results[scope] = packages
                if failed { unavailable.append(scope) }
                if let npm { effectiveContext = .init(homebrewAvailable: context.homebrewAvailable, npm: npm, nodeAvailable: true) }
            }
            try Task.checkCancellation()
            return (CatalogProviderScope.allCases.flatMap { results[$0, default: []] }, effectiveContext,
                    CatalogProviderScope.allCases.filter { unavailable.contains($0) })
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
    private let model: AppModel
    private var previewRequest: UUID?
    private var preparationTask: Task<BatchPlan, Error>?

    init(model: AppModel) { self.model = model }

    func preview(_ input: String, scope: CatalogProviderScope) async {
        guard !isSubmitting, !isPreparing, !model.isBusy else { return }
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
        } catch let error as DiscoverInputError { self.error = error }
        catch { if previewRequest == request { self.error = .installationFailed } }
    }

    func dismissPreview() {
        previewRequest = nil
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
        preview = nil
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
        guard !model.isBusy else { error = .installationFailed; return }
        error = nil
        result = nil
        do {
            guard valid(plan.intent), !Task.isCancelled else { throw DiscoverInputError.staleContext }
            result = try await model.executeBatch(plan)
        } catch let error as DiscoverInputError { self.error = error }
        catch { self.error = .installationFailed }
    }
}

extension AppModel {
    var discoverContext: DiscoverContext {
        let npm: DiscoverNPMContext?
        if let node, let environment = nodePackageEnvironment,
           let registry = SourceConfiguration.registryURL(node.summary.registry) {
            npm = DiscoverNPMContext(environment: environment, registryURL: registry)
        } else { npm = nil }
        return DiscoverContext(homebrewAvailable: homebrew?.executablePath != nil && canMutatePackages(in: .homebrew(.formula)), npm: npm,
                               nodeAvailable: !nodeRefreshFailed && node != nil && node?.summary.nodePath.isEmpty == false && node?.summary.npmPath.isEmpty == false)
    }
}
