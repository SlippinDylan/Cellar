import Combine
import Foundation

enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome
    case coreTools
    case environment
    case complete

    var next: Self? {
        Self(rawValue: rawValue + 1)
    }

    var previous: Self? {
        Self(rawValue: rawValue - 1)
    }
}

@MainActor
final class OnboardingState: ObservableObject {
    static let completedKey = "onboarding.completed"

    @Published private(set) var isCompleted: Bool

    private let defaults: UserDefaults
    private let isRunningTests: Bool

    init(defaults: UserDefaults = .standard, isRunningTests: Bool = AppRuntime.isRunningTests) {
        self.defaults = defaults
        self.isRunningTests = isRunningTests
        isCompleted = defaults.bool(forKey: Self.completedKey)
    }

    var shouldPresentOnLaunch: Bool {
        !isRunningTests && !isCompleted
    }

    func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
        isCompleted = true
    }
}
