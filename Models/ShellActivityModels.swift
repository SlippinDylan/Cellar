import Foundation

enum ShellActivityStep: String, Codable, CaseIterable, Hashable, Sendable {
    case plugins, theme, tidy, ohMyZshInstall, customPluginInstall
    var title: LocalizedStringResource {
        switch self {
        case .plugins: LocalizedStringResource("Plugin Selection")
        case .theme: LocalizedStringResource("Local Theme")
        case .tidy: LocalizedStringResource("Zsh File Tidy")
        case .ohMyZshInstall: LocalizedStringResource("Oh My Zsh Installation")
        case .customPluginInstall: LocalizedStringResource("Custom Plugin Installation")
        }
    }
    init(action: ShellAction) {
        self = switch action {
        case .setPlugins: .plugins
        case .switchTheme: .theme
        case .tidy: .tidy
        case .installOhMyZsh: .ohMyZshInstall
        case .installPlugin: .customPluginInstall
        }
    }
}

struct ShellStepOutcome: Equatable, Sendable {
    let step: ShellActivityStep
    let status: BatchItemStatus
    var summary: ActivityItemSummary {
        .init(displayName: "", status: status,
              reason: status == .succeeded ? nil : status == .cancelled ? .cancelledByUser : status == .unknown ? .stateUnavailable : .providerFailure,
              shellStep: step)
    }
}

extension ShellConfigurationResult {
    func activitySummary(at date: Date = Date()) -> ActivitySummary {
        .init(id: UUID(), operation: .configuration, scope: .shell, targetDisplayNames: [], date: date, status: status, itemOutcomes: stepOutcomes.map(\.summary))
    }
}
