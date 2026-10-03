import Foundation

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case library
    case discover
    case updates
    case tools
    case activity

    static let primaryDestinations: [Self] = [.home, .library, .discover, .updates, .tools]
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: LocalizedStringResource("Home")
        case .library: LocalizedStringResource("Library")
        case .discover: LocalizedStringResource("Discover")
        case .updates: LocalizedStringResource("Updates")
        case .tools: LocalizedStringResource("Tools")
        case .activity: LocalizedStringResource("Activity")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .discover: "safari"
        case .updates: "arrow.down.circle"
        case .tools: "wrench.and.screwdriver"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

enum AppShellAction {
    case refresh
    case show(AppDestination)
    case cancel
}

enum SettingsPane: String, CaseIterable {
    case general
    case sources
    case terminal
    case about
}
