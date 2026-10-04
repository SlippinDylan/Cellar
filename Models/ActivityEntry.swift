import Foundation

struct ActivityEntry: Identifiable, Sendable {
    enum Outcome: String, Sendable {
        case started
        case succeeded
        case partiallySucceeded
        case failed
        case cancelled

        var label: String {
            switch self {
            case .started: "进行中"
            case .succeeded: "成功"
            case .partiallySucceeded: "部分完成"
            case .failed: "失败"
            case .cancelled: "已取消"
            }
        }
    }

    let id: UUID
    let date: Date
    let title: String
    let outcome: Outcome
    let detail: String
    let command: HomebrewCommandOutput?

    init(
        id: UUID,
        date: Date,
        title: String,
        outcome: Outcome,
        detail: String,
        command: HomebrewCommandOutput? = nil
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.outcome = outcome
        self.detail = detail
        self.command = command
    }
}
