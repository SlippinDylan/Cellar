import Foundation

struct ShellSnapshotPayload: Decodable, Sendable {
    let zshVersion: String
    let ohMyZshInstalled: Bool
    let ohMyZshPath: String
    let zshrcPath: String
    let zshrcExists: Bool
    let currentTheme: String
    let activePlugins: [String]
    let installedCustomPlugins: [String]
    let availableThemes: [String]
    let defaultPluginNames: [String]
    let runtimeDirectory: String
}

enum ShellAction: String, Codable, Sendable {
    case installOhMyZsh = "install-omz"
    case installPlugin = "install-plugin"
    case setPlugins = "set-plugins"
    case switchTheme = "switch-theme"
    case tidy
}

struct ShellActionRequest: Sendable, Equatable {
    let action: ShellAction
    let subject: String

    init(action: ShellAction, subject: String = "") {
        self.action = action
        self.subject = subject
    }
}

struct ShellActionPlanPayload: Decodable, Sendable {
    let action: String
    let subject: String
    let targetPath: String
    let requiresConfirmation: Bool
    let executable: Bool
    let blockedReason: String
    let planToken: String
    let generatedAt: Int
}

struct ShellActionPlan: Identifiable, Sendable {
    let id: UUID
    let request: ShellActionRequest
    let payload: ShellActionPlanPayload
    let generatedAt: Date
    var candidates: [String] = []

    var canExecute: Bool { payload.executable }
}

struct ShellOperationResult: Decodable, Sendable {
    let operationId: String
    let action: String
    let subject: String
    let status: String
    let exitCode: Int
    let logFile: String
    let backupPath: String
}

struct ShellActionResult: Sendable {
    let plan: ShellActionPlan
    let operation: ShellOperationResult
    let snapshot: ShellStatus?
    let postflightError: String?
}
