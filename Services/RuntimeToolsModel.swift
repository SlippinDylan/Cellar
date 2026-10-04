import Combine
import Foundation

@MainActor
final class RuntimeToolsModel: ObservableObject {
    @Published private(set) var releases: [OfficialNodeRelease] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    let loadReleases: @Sendable () async throws -> [OfficialNodeRelease]
    init(loadReleases: @escaping @Sendable () async throws -> [OfficialNodeRelease] = { try await OfficialNodeReleaseClient().releases() }) {
        self.loadReleases = loadReleases
    }
    func refresh(model: AppModel) async {
        guard !model.isBusy else { return }
        let id = model.operationStore.begin()
        isLoading = true
        error = nil
        defer { isLoading = false; model.operationStore.end(id) }
        do { releases = try await model.operationStore.performCancellable(operationID: id) { try await self.loadReleases() } }
        catch { self.error = error.localizedDescription }
    }
}

extension AppModel {
    func restoreDefaultNodeSession() async {
        guard !isBusy else { return }
        let installed = await service.runtimeInstallations(preferredVersion: preferredNodeVersion)
        guard installed.contains(where: \.isDefault) else {
            nodeOperationError = String(localized: "The nvm default cannot be resolved. Select an installed version or set a default.")
            return
        }
        preferredNodeVersion = nil
        await refresh()
    }
}
