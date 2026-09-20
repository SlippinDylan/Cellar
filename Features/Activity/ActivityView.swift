import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.activities.isEmpty {
                ContentUnavailableView(
                    "暂无操作记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("本次 App 会话中的刷新结果会显示在这里")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.activities, selection: $selection) {
                    TableColumn("时间") { entry in
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                    }
                    TableColumn("操作", value: \.title)
                    TableColumn("状态") { entry in
                        Text(entry.outcome.label)
                    }
                    TableColumn("详情", value: \.detail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let command = selectedCommand {
                    GroupBox("命令结果") {
                        ScrollView {
                            Text(commandText(command))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private var selectedCommand: HomebrewCommandOutput? {
        guard let selection else { return nil }
        return model.activities.first { $0.id == selection }?.command
    }

    private func commandText(_ command: HomebrewCommandOutput) -> String {
        var sections = [
            "参数：brew \(command.arguments.joined(separator: " "))",
            "退出状态：\(command.terminationStatus)",
        ]
        if !command.standardOutput.isEmpty {
            sections.append("stdout:\n\(command.standardOutput)")
        }
        if !command.standardError.isEmpty {
            sections.append("stderr:\n\(command.standardError)")
        }
        if command.standardOutputWasTruncated || command.standardErrorWasTruncated {
            sections.append("注意：输出超过安全上限，已截断。")
        }
        return sections.joined(separator: "\n\n")
    }
}
