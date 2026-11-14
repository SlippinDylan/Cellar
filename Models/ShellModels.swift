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
    var detail: String? = nil
}

struct ShellActionResult: Sendable {
    let plan: ShellActionPlan
    let operation: ShellOperationResult
    let snapshot: ShellStatus?
    let postflightError: String?
    var executionOutcome: ActivityStatus? = nil
}

// Failure evidence is not proof that an operation completed or changed anything.
struct ShellExecutionFailure: LocalizedError {
    let operation: ShellOperationResult?
    let cause: any Error
    var outcome: ActivityStatus = .unknown
    var movedPaths: [String] = []
    var verificationError: String? = nil
    var errorDescription: String? { cause.localizedDescription }
    var diagnosticDetail: String {
        var details = [cause.localizedDescription]
        if let operation {
            details += [operation.operationId, "exitCode=\(operation.exitCode)", operation.status, operation.logFile, operation.backupPath]
        }
        details += movedPaths
        if let verificationError { details.append(verificationError) }
        return details.joined(separator: "\n")
    }
    var reason: ActivityItemReason { outcome == .unknown ? .stateUnavailable : .init(error: cause) }
}

struct ShellExecutionErrorPayload: Decodable, Sendable {
    let code: String
    let operation: ShellOperationResult

    init(from decoder: any Decoder) throws {
        enum CodingKeys: CodingKey { case code }
        code = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .code)
        operation = try ShellOperationResult(from: decoder)
    }
}

struct ShellExecutionErrorEnvelope: Decodable, Sendable {
    let error: ShellExecutionErrorPayload
}
