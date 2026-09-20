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
    let managerAvailable: Bool
}

struct SnapshotStatus: Sendable {
    let version: String
    let location: String
    let nodeAvailable: Bool
    let homebrewAvailable: Bool
    let shellAvailable: Bool
}

struct DashboardSnapshot: Sendable {
    let homebrew: HomebrewStatus
    let node: NodeSnapshot
    let shell: ShellStatus
    let managers: SnapshotStatus
    let refreshedAt: Date
}
