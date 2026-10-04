import Foundation

enum BridgeError: LocalizedError {
    case executableNotFound(String)
    case invalidOutput(String)
    case managerFailure(code: String, detail: String?)
    case processTimedOut(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return String(localized: "Executable unavailable: \(name)")
        case .invalidOutput(let detail):
            return String(localized: "The provider returned unrecognized data: \(detail)")
        case .managerFailure(let code, let detail):
            if let detail { return String(localized: "Provider task failed (\(code)): \(detail)") }
            return String(localized: "Provider task failed: \(code)")
        case .processTimedOut(let executable):
            return String(localized: "The task timed out and was stopped: \(executable)")
        case .unsupportedSchema(let version):
            let value = String(version)
            return String(localized: "Unsupported Manager schema: \(value)")
        }
    }
}
