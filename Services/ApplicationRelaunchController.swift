import AppKit

@MainActor
final class ApplicationRelaunchController {
    static let shared = ApplicationRelaunchController()

    private let operationStore: OperationStore
    private let terminateApplication: () -> Void
    private var isRelaunchRequested = false

    init(operationStore: OperationStore = .shared, terminateApplication: @escaping () -> Void = {
        NSApplication.shared.terminate(nil)
    }) {
        self.operationStore = operationStore
        self.terminateApplication = terminateApplication
    }

    @discardableResult
    func changeLanguage(_ language: ApplicationLanguage, in defaults: UserDefaults = .standard) -> Bool {
        guard !operationStore.hasActiveOperations, !isRelaunchRequested else { return false }
        guard ApplicationLanguage.select(language, in: defaults) else { return false }
        // Bundle localization is selected at process startup, so preferences alone are insufficient.
        isRelaunchRequested = true
        terminateApplication()
        return true
    }

    func cancelRelaunchRequest() {
        isRelaunchRequested = false
    }

    func consumeRelaunchRequest() -> Bool {
        defer { isRelaunchRequested = false }
        return isRelaunchRequested
    }
}

enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func shouldRefreshOnLaunch(refreshedAt: Date?, environment: [String: String]) -> Bool {
        refreshedAt == nil && environment["XCTestConfigurationFilePath"] == nil
    }
}
