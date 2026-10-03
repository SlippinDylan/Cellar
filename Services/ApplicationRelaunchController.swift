import AppKit
import Combine

@MainActor
final class ApplicationRelaunchController: ObservableObject {
    static let shared = ApplicationRelaunchController()

    private let operationStore: OperationStore
    private let defaults: UserDefaults
    private let defaultsDomainName: String
    private let terminateApplication: () -> Void
    @Published private(set) var selectedLanguage: ApplicationLanguage
    private var pendingLanguageChange: LanguageChange?

    private struct LanguageChange {
        let previousSelection: ApplicationLanguage
        let previousPreference: Any?
        let previousAppleLanguages: Any?
    }

    private static var applicationDomainName: String {
        guard let identifier = Bundle.main.bundleIdentifier else {
            preconditionFailure("The app bundle must include a bundle identifier")
        }
        return identifier
    }

    init(operationStore: OperationStore = .shared, defaults: UserDefaults = .standard,
         defaultsDomainName: String = ApplicationRelaunchController.applicationDomainName,
         terminateApplication: @escaping () -> Void = {
        NSApplication.shared.terminate(nil)
    }) {
        self.operationStore = operationStore
        self.defaults = defaults
        self.defaultsDomainName = defaultsDomainName
        selectedLanguage = ApplicationLanguage.selected(in: defaults)
        self.terminateApplication = terminateApplication
    }

    @discardableResult
    func changeLanguage(_ language: ApplicationLanguage) -> Bool {
        guard !operationStore.hasActiveOperations, pendingLanguageChange == nil else { return false }
        // Read the app domain itself: inherited system languages must not become an app override.
        let domain = defaults.persistentDomain(forName: defaultsDomainName)
        let previous = LanguageChange(previousSelection: selectedLanguage,
                                      previousPreference: domain?[ApplicationLanguage.preferenceKey],
                                      previousAppleLanguages: domain?[ApplicationLanguage.appleLanguagesKey])
        guard ApplicationLanguage.select(language, in: defaults) else { return false }
        // Bundle localization is selected at process startup, so preferences alone are insufficient.
        pendingLanguageChange = previous
        selectedLanguage = language
        terminateApplication()
        return true
    }

    func cancelRelaunchRequest() {
        guard let previous = pendingLanguageChange else { return }
        defaults.set(previous.previousPreference, forKey: ApplicationLanguage.preferenceKey)
        defaults.set(previous.previousAppleLanguages, forKey: ApplicationLanguage.appleLanguagesKey)
        pendingLanguageChange = nil
        selectedLanguage = previous.previousSelection
    }

    func consumeRelaunchRequest() -> Bool {
        guard pendingLanguageChange != nil else { return false }
        pendingLanguageChange = nil
        return true
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
