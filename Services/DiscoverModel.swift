import Combine
import Foundation

struct DiscoverSearchDependencies: Sendable {
    let homebrew: @Sendable (String, HomebrewPackageKind, Int) async throws -> [HomebrewPackage]
    let npm: @Sendable (String, DiscoverNPMContext, Int) async throws -> [NPMCatalogResult]

    static func live(service: SystemProbeService) -> Self {
        let http = CatalogHTTPClient()
        return Self(homebrew: { try await service.discoverHomebrew($0, kind: $1, limit: $2) },
                    npm: { query, context, limit in
            try await NPMRegistryClient(registryURL: context.registryURL, http: http).search(query, environment: context.environment, limit: limit)
        })
    }
}

@MainActor
final class DiscoverSearchModel: ObservableObject {
    @Published private(set) var state = DiscoverSearchState.idle
    @Published private(set) var results: [DiscoverResult] = []
    @Published private(set) var resultContext: DiscoverContext?
    private let dependencies: DiscoverSearchDependencies
    private let operationStore: OperationStore
    private var latestRequest: UUID?
    private var owner: (id: UUID, task: Task<Void, Never>)?
    private var cancellationObserver: AnyCancellable?

    init(dependencies: DiscoverSearchDependencies, operationStore: OperationStore) {
        self.dependencies = dependencies
        self.operationStore = operationStore
        cancellationObserver = operationStore.$activeTask.sink { [weak self] task in
            guard let self, let task, task.id == self.owner?.id, task.cancellationRequested else { return }
            // The menu's Cancel also withdraws a replacement waiting for old work to exit.
            self.latestRequest = nil
            self.owner?.task.cancel()
            self.state = .cancelled
        }
    }

    func invalidate() {
        latestRequest = nil
        owner?.task.cancel()
        state = .idle
        results = []
        resultContext = nil
    }

    func search(_ query: String, scope: CatalogProviderScope, context: DiscoverContext, limit: Int = 50) async {
        let request = UUID()
        latestRequest = request
        results = []
        resultContext = nil
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
        let operationID = operationStore.begin()
        let task = Task { await self.run(term, scope: scope, context: context, limit: limit, request: request, operationID: operationID) }
        owner = (operationID, task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if owner?.id == operationID { owner = nil }
    }

    static func guidance(_ scope: CatalogProviderScope, context: DiscoverContext) -> DiscoverSearchState? {
        switch scope {
        case .homebrewFormula, .homebrewCask: context.homebrewAvailable ? nil : .homebrewRequired
        case .npm: context.npm == nil ? (context.nodeAvailable ? .registryRequired : .nodeRequired) : nil
        }
    }

    private func run(_ query: String, scope: CatalogProviderScope, context: DiscoverContext, limit: Int,
                     request: UUID, operationID: UUID) async {
        defer { operationStore.end(operationID) }
        do {
            let results = try await operationStore.performCancellable(operationID: operationID) {
                let values: [DiscoverResult]
                switch scope {
                case .homebrewFormula, .homebrewCask:
                    let kind: HomebrewPackageKind = scope == .homebrewFormula ? .formula : .cask
                    values = try await self.dependencies.homebrew(query, kind, limit).prefix(limit).map(DiscoverResult.homebrew)
                case .npm:
                    guard let npm = context.npm else { preconditionFailure("npm search requires a validated context") }
                    values = try await self.dependencies.npm(query, npm, limit).prefix(limit).map(DiscoverResult.npm)
                }
                try Task.checkCancellation()
                return values
            }
            guard latestRequest == request, !Task.isCancelled else { return }
            self.results = results
            resultContext = context
            state = results.isEmpty ? .empty : .available
        } catch {
            guard latestRequest == request else { return }
            state = error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled ? .cancelled : .failed
        }
    }
}

@MainActor
final class DiscoverInstallationModel: ObservableObject {
    @Published private(set) var preview: DiscoverInstallPreview?
    @Published private(set) var result: BatchExecutionResult?
    @Published private(set) var error: DiscoverInputError?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func preview(_ input: String, scope: CatalogProviderScope) {
        preview = nil
        error = nil
        do {
            if scope != .npm, !model.discoverContext.homebrewAvailable { throw DiscoverInputError.missingContext }
            if scope == .npm, model.nodeRefreshFailed { throw DiscoverInputError.missingContext }
            let npm = scope == .npm ? model.discoverContext.npm : nil
            let intent = try DiscoverBatchInput.intent(input, scope: scope, npm: npm)
            preview = DiscoverInstallPreview(intent: intent, npm: npm)
        } catch let error as DiscoverInputError { self.error = error }
        catch { preconditionFailure("Input validation only throws DiscoverInputError") }
    }

    func dismissPreview() { preview = nil }

    func confirmInstall() async {
        guard let preview else { return }
        self.preview = nil
        // Consume the user's confirmation once, before any asynchronous preparation.
        guard valid(preview.intent, npm: preview.npm) else { error = .staleContext; return }
        await execute(preview.intent, npm: preview.npm)
    }

    func install(_ card: CatalogCardState, context: DiscoverContext) async {
        guard card.primaryAction == .install, card.progress == .idle,
              let intent = BatchIntent(operation: .install, items: [card.batchItem]) else { return }
        let npm = card.identity.providerScope == .npm ? context.npm : nil
        guard valid(intent, npm: npm) else { error = .staleContext; return }
        await execute(intent, npm: npm)
    }

    private func valid(_ intent: BatchIntent, npm: DiscoverNPMContext?) -> Bool {
        switch intent.scope {
        case .homebrew: return model.discoverContext.homebrewAvailable
        case .npm(let environment): return !model.nodeRefreshFailed && npm == model.discoverContext.npm && npm?.environment == environment
        case .nodeRuntime: return false
        }
    }

    private func execute(_ intent: BatchIntent, npm: DiscoverNPMContext?) async {
        guard !model.isBusy else { error = .installationFailed; return }
        error = nil
        result = nil
        do {
            let plan = try await model.prepareBatch(intent)
            guard valid(intent, npm: npm), !Task.isCancelled else { throw DiscoverInputError.staleContext }
            if let npm, !plan.npmRegistryURLs.allSatisfy({ $0 == npm.registryURL }) { throw DiscoverInputError.staleContext }
            result = try await model.executeBatch(plan)
        } catch let error as DiscoverInputError { self.error = error }
        catch { self.error = .installationFailed }
    }
}

extension AppModel {
    var discoverContext: DiscoverContext {
        let npm: DiscoverNPMContext?
        if let node, !node.summary.nodePath.isEmpty, !node.summary.npmPath.isEmpty,
           let registry = URL(string: node.summary.registry), (try? NPMRegistryClient(registryURL: registry)) != nil {
            npm = DiscoverNPMContext(environment: LibraryCatalog.context(node.summary), registryURL: registry)
        } else { npm = nil }
        return DiscoverContext(homebrewAvailable: homebrew?.executablePath != nil && !homebrewRefreshFailed, npm: npm,
                               nodeAvailable: node != nil && node?.summary.nodePath.isEmpty == false && node?.summary.npmPath.isEmpty == false)
    }
}
