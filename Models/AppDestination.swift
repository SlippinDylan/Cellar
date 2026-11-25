import Foundation

enum MainWindowIdentity: String, Codable, Hashable { case main }

enum AppScene {
    static let mainWindowID = "main"
    static let onboardingWindowID = "onboarding"
}

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case library
    case discover
    case tools
    case maintenance
    case settings
    case about

    static let primaryDestinations: [Self] = [.home, .library, .discover, .tools, .maintenance]
    static let bottomDestinations: [Self] = [.settings, .about]
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: LocalizedStringResource("Home")
        case .library: LocalizedStringResource("Library")
        case .discover: LocalizedStringResource("Discover")
        case .tools: LocalizedStringResource("Environment")
        case .maintenance: LocalizedStringResource("Maintenance")
        case .settings: LocalizedStringResource("Settings")
        case .about: LocalizedStringResource("About")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .discover: "safari"
        case .tools: "wrench.and.screwdriver"
        case .maintenance: "stethoscope"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

enum AppShellAction {
    case refresh
    case show(AppDestination)
}
