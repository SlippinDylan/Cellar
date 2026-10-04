import Foundation

extension AppModel {
    func prepareTerminalConfiguration(plugins: [String], theme: String) async {
        guard !isBusy, let managers else { return }
        isShellWorking = true
        shellOperationError = nil
        terminalConfigurationResult = nil
        let operationID = operationStore.begin()
        defer { isShellWorking = false; operationStore.end(operationID) }
        do {
            terminalConfigurationPlan = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.planTerminalConfiguration(plugins: plugins, theme: theme, snapshot: managers)
            }
        }
        catch { shellOperationError = error.localizedDescription }
    }

    func executeTerminalConfiguration(_ confirmed: ShellConfigurationPlan) async {
        guard !isBusy, let managers, terminalConfigurationPlan?.id == confirmed.id, confirmed.canExecute else { return }
        terminalConfigurationPlan = nil
        isShellWorking = true
        shellOperationError = nil
        let operationID = operationStore.begin()
        defer { isShellWorking = false; operationStore.end(operationID) }
        let result: ShellConfigurationResult
        do {
            result = try await operationStore.performCancellable(operationID: operationID) {
                await self.service.executeTerminalConfiguration(confirmed, snapshot: managers)
            }
        } catch {
            let cancelled = error is CancellationError
            result = .init(operations: [], failure: error.localizedDescription, wasCancelled: cancelled,
                           stepOutcomes: confirmed.plans.map { .init(step: .init(action: $0.request.action), status: cancelled ? .cancelled : .unknown) })
        }
        terminalConfigurationResult = result
        shellOperationError = result.failure
        let refresh = Task { try await service.loadShell(snapshot: managers) }
        do { shell = try await refresh.value; refreshedAt = Date() }
        catch { shellOperationError = error.localizedDescription }
        var summary = result.activitySummary()
        if shellOperationError != nil && summary.status == .succeeded {
            summary = .init(id: summary.id, operation: summary.operation, scope: summary.scope, targetDisplayNames: [], date: summary.date,
                            status: .partiallySucceeded, itemOutcomes: summary.itemOutcomes)
        }
        activityStore?.append(summary)
    }

    func openRuntimeTools() {
        selectedToolsCategory = .runtime
        selectedDestination = .tools
    }
}
