import Foundation

enum ToolsCategory: String, CaseIterable, Identifiable {
    case environment, runtime, project, diagnostics, maintenance
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .environment: LocalizedStringResource("Environment Setup")
        case .runtime: LocalizedStringResource("Runtime")
        case .project: LocalizedStringResource("Project")
        case .diagnostics: LocalizedStringResource("Diagnostics")
        case .maintenance: LocalizedStringResource("Maintenance")
        }
    }
}

enum NodeMaintenanceAction: String, CaseIterable, Identifiable {
    case verify = "npm-cache-verify"
    case npmCache = "npm-cache-clean"
    case nodeGyp = "node-gyp-cache"
    case orphanBins = "orphan-bins"
    case oldNode = "nvm-old-versions"
    case logs
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .verify: LocalizedStringResource("Verify npm Cache")
        case .npmCache: LocalizedStringResource("Clear npm Cache")
        case .nodeGyp: LocalizedStringResource("Clear Build Cache")
        case .orphanBins: LocalizedStringResource("Remove Broken npm Links")
        case .oldNode: LocalizedStringResource("Remove Unused Node Versions")
        case .logs: LocalizedStringResource("Keep Recent Manager Logs")
        }
    }
    var detail: LocalizedStringResource {
        switch self {
        case .verify: LocalizedStringResource("Check npm’s cache without deleting cached packages.")
        case .npmCache: LocalizedStringResource("Remove cached npm downloads from the confirmed cache directory.")
        case .nodeGyp: LocalizedStringResource("Remove only the confirmed node-gyp build cache directories.")
        case .orphanBins: LocalizedStringResource("Remove only npm command links that are still broken at execution.")
        case .oldNode: LocalizedStringResource("Remove only old versions without user global packages. Current and default versions are protected.")
        case .logs: LocalizedStringResource("Keep the 100 most recent Manager logs and remove older logs.")
        }
    }
    var request: NodeActionRequest { .init(action: .cleanup, subject: rawValue, value: self == .logs ? "100" : nil) }
}

enum RuntimeProtection {
    static func canUninstall(_ installation: NodeInstallation) -> Bool { !installation.isActive && !installation.isDefault }
}

struct OfficialNodeRelease: Decodable, Identifiable, Sendable {
    let version: String
    let files: [String]
    var id: String { version }
}
