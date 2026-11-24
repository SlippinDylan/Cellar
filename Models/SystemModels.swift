import Foundation

struct HomebrewStatus: Sendable {
    let executablePath: String?
    let version: String?
    let managerAvailable: Bool
    let snapshot: HomebrewSnapshot?

    var isInstalled: Bool { executablePath != nil }
}

struct ShellStatus: Sendable {
    let zshVersion: String?
    let ohMyZshPath: String
    let ohMyZshInstalled: Bool
    let zshrcPath: String
    let zshrcExists: Bool
    let currentTheme: String
    let activePlugins: [String]
    let installedCustomPlugins: [String]
    let availableThemes: [String]
    let defaultPluginNames: [String]
    let runtimeDirectory: String
    let managerAvailable: Bool
}

struct SnapshotStatus: Sendable {
    let version: String
    let location: String
    let nodeAvailable: Bool
    let homebrewAvailable: Bool
    let shellAvailable: Bool
}
