import Combine
import Foundation

enum ProtectedFileAccessResult: Sendable, Equatable {
    case verified, denied, unavailable
}

@MainActor
final class ProtectedFileAccessVerification: ObservableObject {
    @Published private(set) var result: ProtectedFileAccessResult?
    private let checkAccess: @Sendable () async -> ProtectedFileAccessResult
    private var requestID: UUID?

    var isVerified: Bool { result == .verified }

    init(checkAccess: @escaping @Sendable () async -> ProtectedFileAccessResult = ProtectedFileAccessVerification.liveCheck) {
        self.checkAccess = checkAccess
    }

    func refresh() async {
        let id = UUID()
        requestID = id
        result = nil
        let checked = await checkAccess()
        guard requestID == id, !Task.isCancelled else { return }
        result = checked
    }

    func invalidate() {
        requestID = nil
        result = nil
    }

    nonisolated static func readResult(directory: URL) -> ProtectedFileAccessResult {
        do {
            try CaskRemovalFileSystem.verifyDirectoryReadAccess(directory.path)
            return .verified
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            return .denied
        } catch {
            return .unavailable
        }
    }

    static func liveCheck() async -> ProtectedFileAccessResult {
        guard !AppRuntime.isRunningTests else { return .unavailable }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Cookies")
        let worker = Task.detached(priority: .utility) { readResult(directory: directory) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
