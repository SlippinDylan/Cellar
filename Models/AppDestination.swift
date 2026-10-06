import Foundation

enum MainWindowIdentity: String, Codable, Hashable { case main }

enum AppScene {
    static let mainWindowID = "main"
}

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case library
    case discover
    case tools
    case settings
    case activity

    static let primaryDestinations: [Self] = [.home, .library, .discover, .tools]
    static let bottomDestinations: [Self] = [.settings, .activity]
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: LocalizedStringResource("Home")
        case .library: LocalizedStringResource("Library")
        case .discover: LocalizedStringResource("Discover")
        case .tools: LocalizedStringResource("Tools")
        case .settings: LocalizedStringResource("Settings")
        case .activity: LocalizedStringResource("Activity")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .discover: "safari"
        case .tools: "wrench.and.screwdriver"
        case .settings: "gearshape"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

enum AppShellAction {
    case refresh
    case show(AppDestination)
}

enum SettingsPane: String, CaseIterable {
    case general
    case sources
    case terminal
    case about
}
