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
            "找不到可执行文件：\(name)"
        case .invalidOutput(let detail):
            "命令返回了无法识别的数据：\(detail)"
        case .managerFailure(let code, let detail):
            detail.map { "Manager 执行失败（\(code)）：\($0)" } ?? "Manager 执行失败：\(code)"
        case .processTimedOut(let executable):
            "命令执行超时并已终止：\(executable)"
        case .unsupportedSchema(let version):
            "不支持 Manager JSON schema v\(version)"
        }
    }
}
