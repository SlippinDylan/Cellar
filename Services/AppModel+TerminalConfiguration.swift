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
        } catch { result = .init(operations: [], failure: error.localizedDescription, wasCancelled: error is CancellationError) }
        terminalConfigurationResult = result
        shellOperationError = result.failure
        let refresh = Task { try await service.loadShell(snapshot: managers) }
        do { shell = try await refresh.value; refreshedAt = Date() }
        catch { shellOperationError = error.localizedDescription }
        let status: ActivityStatus = result.wasCancelled ? .cancelled : shellOperationError == nil ? result.status : result.operations.isEmpty ? .failed : .partiallySucceeded
        activityStore?.append(.init(id: UUID(), operation: .configuration, scope: nil, targetDisplayNames: [], date: Date(), status: status, itemOutcomes: []))
    }

    func openRuntimeTools() {
        selectedToolsCategory = .runtime
        selectedDestination = .tools
    }
}
