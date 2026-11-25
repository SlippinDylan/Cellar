import AppKit
import Combine
import Foundation

enum LibraryUninstallPathGuidance: Equatable {
    case protectedData, manualRemoval, quitAndRetry
    case reviewFailure(ActivityItemReason)
    case homebrewRemoved(ActivityItemReason?)

    init?(entry: CaskRemovalEntry, status: CaskRemovalPathStatus, hasFinished: Bool, failureReason: ActivityItemReason?,
          homebrewWasUninstalled: Bool = false) {
        if entry.disposition == .protected {
            self = .protectedData
        } else if hasFinished && status == .unverified {
            self = .reviewFailure(.stateUnavailable)
        } else if hasFinished && status == .retained {
            if homebrewWasUninstalled {
                self = .homebrewRemoved(failureReason)
                return
            }
            switch failureReason {
            case .applicationRunning: self = .quitAndRetry
            case .some(let reason):
                self = reason == .providerFailure ? .manualRemoval : .reviewFailure(reason)
            default: self = .manualRemoval
            }
        } else {
            return nil
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .protectedData: "This data may be shared or its ownership is unclear. Check the impact before removing it manually."
        case .manualRemoval: "Not removed. Please remove manually in Finder."
        case .quitAndRetry: "The application is still running. Quit it, then review the uninstallation again."
        case .reviewFailure(let reason): reason.message
        case .homebrewRemoved(.applicationRunning):
            "Homebrew removed the package. Quit its remaining processes, then handle this path manually in Finder."
        case .homebrewRemoved(.authorizationFailed), .homebrewRemoved(.permission):
            "Homebrew removed the package. Check authorization and file permissions, then handle this path manually in Finder."
        case .homebrewRemoved(.stateChanged), .homebrewRemoved(.scanIncomplete):
            "Homebrew removed the package. Confirm this path’s ownership and current state before handling it manually in Finder."
        case .homebrewRemoved:
            "Homebrew removed the package, but this path remains. Review it before handling it manually in Finder."
        }
    }
}

@MainActor
final class LibraryUninstallModel: ObservableObject {
    @Published private(set) var presentedItem: BatchItem?
    @Published private(set) var isPreparing = false
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var displayName: String?
    @Published private(set) var confirmation: BatchPlan?
    @Published private(set) var result: BatchExecutionResult?
    @Published private(set) var error: LibraryUninstallError?
    @Published private(set) var failureReason: ActivityItemReason?
    private enum ExecutionState { case notStarted, running, finished }
    @Published private var executionState = ExecutionState.notStarted
    @Published private var pathStatuses: [String: CaskRemovalPathStatus] = [:]
    var isExecuting: Bool { executionState == .running }
    var hasFinished: Bool { executionState == .finished }

    func dismissResult() {
        result = nil
        error = nil
        failureReason = nil
    }

    func dismissError() {
        error = nil
        failureReason = nil
    }
    private let revealFile: (URL) -> Void
    private var preparationID: UUID?
    private var preparationTask: Task<BatchPlan, Error>?
    private var iconTask: Task<Void, Never>?
    private var iconRequestID: UUID?
    private var iconURL: URL?
    private let loadIconData: @Sendable (URL) async -> Data?
    let model: AppModel

    init(model: AppModel, revealFile: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }, loadIconData: @escaping @Sendable (URL) async -> Data? = { url in
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return Data?.none }
            return NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }) {
        self.model = model
        self.revealFile = revealFile
        self.loadIconData = loadIconData
    }

    func prepare(_ item: BatchItem) async {
        guard !model.isBusy, presentedItem == nil else { return }
        confirmation = nil
        result = nil
        error = nil
        failureReason = nil
        guard let intent = LibraryCatalog.uninstallIntent(item) else {
            error = .invalidTarget
            return
        }
        let requestID = UUID()
        preparationID = requestID
        presentedItem = intent.items[0]
        isPreparing = true
        if case .homebrew(let identity) = item,
           let package = model.homebrew?.snapshot?.packages.first(where: { $0.identity == identity }) {
            displayName = package.displayName
            let artifacts = package.artifacts.filter { $0.category == .installed && $0.kind == "app" }.flatMap { artifact in
                if let application = artifact.application {
                    return [application.target ?? URL(filePath: application.source).lastPathComponent]
                }
                return artifact.values
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            startIconLoading(requestID: requestID) {
                let lookup = Task.detached(priority: .utility) { () -> URL? in
                    let roots = [URL(filePath: "/Applications"), home.appending(path: "Applications"),
                                 URL(filePath: "/Library/Input Methods"), home.appending(path: "Library/Input Methods")]
                    for value in artifacts {
                        guard !Task.isCancelled else { return nil }
                        guard value.hasSuffix(".app"), !value.hasPrefix("/Volumes/"),
                              !value.contains(".."), !value.contains("*"), !value.contains("?") else { continue }
                        let candidates: [URL]
                        if value.hasPrefix("/") { candidates = [URL(filePath: value)] }
                        else if value.hasPrefix("~/") { candidates = [home.appending(path: String(value.dropFirst(2)))] }
                        else if !value.contains("/") { candidates = roots.map { $0.appending(path: value) } }
                        else { continue }
                        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return url }
                    }
                    return nil
                }
                return await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
            }
        }
        model.logStore?.record(level: .info, category: "uninstall-preview", message: "Preview preparation started", taskID: requestID)
        defer {
            if preparationID == requestID { isPreparing = false; preparationTask = nil }
        }
        do {
            let task = Task { try await self.model.prepareBatch(intent) }
            preparationTask = task
            let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard preparationID == requestID, !Task.isCancelled else { return }
            confirmation = plan
            let removal = plan.homebrewImpacts.first?.caskRemoval
            model.logStore?.record(level: .info, category: "uninstall-preview",
                                   message: "Preview ready entries=\(removal?.entries.count ?? 0) warnings=\(removal?.warnings.count ?? 0)", taskID: requestID)
            if let appURL = removal?.appURL,
               iconURL != appURL || (iconTask == nil && appIcon == nil) {
                iconTask?.cancel()
                if iconURL != appURL { appIcon = nil }
                startIconLoading(requestID: requestID) { appURL }
            }
        }
        catch BatchOperationError.protectedNode {
            guard preparationID == requestID else { return }
            dismissConfirmation()
            self.error = .protectedTarget
        }
        catch BridgeError.managerFailure(let code, _) where ["protected-package", "cannot-uninstall-current-node", "cannot-uninstall-default-node"].contains(code) {
            guard preparationID == requestID else { return }
            dismissConfirmation()
            self.error = .protectedTarget
        }
        catch {
            guard preparationID == requestID else { return }
            dismissConfirmation()
            self.error = .preparationFailed
            failureReason = .init(error: error, preparing: true)
            _ = model.failureMessage(error, preparing: true)
        }
    }

    private func startIconLoading(requestID: UUID, appURL: @escaping @Sendable () async -> URL?) {
        // Local icon loading runs independently of the potentially slow removal scan.
        let iconID = UUID()
        iconRequestID = iconID
        iconTask = Task { [weak self, loadIconData] in
            let resolvedURL = await appURL()
            guard let self, self.preparationID == requestID, self.iconRequestID == iconID, !Task.isCancelled else { return }
            defer {
                if self.iconRequestID == iconID { self.iconTask = nil; self.iconRequestID = nil }
            }
            guard let url = resolvedURL ?? self.confirmation?.homebrewImpacts.first?.caskRemoval?.appURL else { return }
            self.iconURL = url
            let data = await loadIconData(url)
            guard self.preparationID == requestID, self.iconRequestID == iconID, !Task.isCancelled else { return }
            self.appIcon = data.flatMap { NSImage(data: $0) }
            self.model.logStore?.record(level: .info, category: "uninstall-preview", message: "Local icon loading finished", taskID: requestID)
        }
    }

    func dismissConfirmation() {
        guard !isExecuting else { return }
        if let preparationID {
            model.logStore?.record(level: .info, category: "uninstall-preview", message: "Preview dismissed", taskID: preparationID)
        }
        preparationID = nil
        preparationTask?.cancel()
        preparationTask = nil
        iconTask?.cancel()
        iconTask = nil
        iconRequestID = nil
        iconURL = nil
        presentedItem = nil
        confirmation = nil
        appIcon = nil
        displayName = nil
        isPreparing = false
        executionState = .notStarted
        pathStatuses = [:]
    }

    func pathStatus(_ entry: CaskRemovalEntry) -> CaskRemovalPathStatus {
        pathStatuses[entry.path] ?? (entry.disposition == .protected ? .retained : .pending)
    }

    func guidance(for entry: CaskRemovalEntry) -> LibraryUninstallPathGuidance? {
        let reason = cleanupFailure(for: entry)?.recoveryReason ?? failureReason ?? result?.outcome.itemOutcomes.first?.reason
        return .init(entry: entry, status: pathStatus(entry), hasFinished: hasFinished, failureReason: reason,
                     homebrewWasUninstalled: homebrewWasUninstalled)
    }

    private var homebrewWasUninstalled: Bool {
        guard let result, let provider = result.providerResults.first, case .homebrew(let homebrew) = provider,
              homebrew.command.terminationStatus == 0, let snapshot = homebrew.snapshot,
              snapshot.sectionErrors[.packages] == nil else { return false }
        return !snapshot.packages.contains { homebrew.plan.targets.contains($0.identity) && $0.isInstalled }
    }

    private func cleanupFailure(for entry: CaskRemovalEntry) -> CaskRemovalFailure? {
        guard let result, let provider = result.providerResults.first,
              case .homebrew(let homebrew) = provider else { return nil }
        return homebrew.caskRemovalFailures.first { $0.path == entry.path }
    }

    func revealInFinder(_ entry: CaskRemovalEntry) {
        guard confirmation?.homebrewImpacts.first?.caskRemoval?.entries.contains(entry) == true,
              pathStatus(entry) != .removed else { return }
        revealFile(URL(filePath: entry.path))
    }

    private func receive(_ progress: CaskRemovalProgress, requestID: UUID) {
        guard preparationID == requestID, isExecuting,
              let entry = confirmation?.homebrewImpacts.first?.caskRemoval?.entries.first(where: { $0.path == progress.path }),
              entry.disposition != .protected else { return }
        pathStatuses[progress.path] = progress.status
    }

    func confirmUninstall() async {
        guard let confirmation, !isExecuting, !hasFinished else { return }
        guard let removal = confirmation.homebrewImpacts.first?.caskRemoval, let requestID = preparationID else {
            dismissConfirmation()
            do { result = try await model.executeBatch(confirmation) }
            catch { self.error = .executionRefused; failureReason = .init(error: error); _ = model.failureMessage(error) }
            return
        }
        executionState = .running
        pathStatuses = Dictionary(uniqueKeysWithValues: removal.entries.map { ($0.path, $0.disposition == .protected ? .retained : .pending) })
        defer {
            // Unreported or interrupted paths are never presented as successfully removed.
            for entry in removal.entries where pathStatus(entry) == .pending || pathStatus(entry) == .removing {
                pathStatuses[entry.path] = .retained
            }
            executionState = .finished
        }
        do {
            result = try await model.executeBatch(confirmation, caskRemovalProgress: { [weak self] progress in
                await self?.receive(progress, requestID: requestID)
            })
            if let result, let provider = result.providerResults.first, case .homebrew(let homebrew) = provider {
                for path in homebrew.caskRemovalPathResults { pathStatuses[path.path] = path.progress.status }
            }
        } catch {
            self.error = .executionRefused
            failureReason = .init(error: error)
            _ = model.failureMessage(error)
        }
    }
}

enum LibraryUninstallError: Equatable {
    case invalidTarget, protectedTarget, preparationFailed, executionRefused
}
