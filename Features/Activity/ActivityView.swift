import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        if model.activities.isEmpty {
            ContentUnavailableView(
                "暂无操作记录",
                systemImage: "clock.arrow.circlepath",
                description: Text("本次 App 会话保留最近 100 条刷新和操作结果。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VSplitView {
                Table(model.activities, selection: $selection) {
                    TableColumn("状态") { entry in
                        Label(entry.outcome.label, systemImage: entry.outcome.systemImage)
                            .foregroundStyle(entry.outcome.tint)
                    }
                    .width(min: 90, ideal: 110, max: 140)
                    TableColumn("操作", value: \.title)
                    TableColumn("时间") { entry in
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 100, max: 120)
                    TableColumn("摘要", value: \.detail)
                }
                .alternatingRowBackgrounds(.disabled)
                .frame(minHeight: 240)

                inspector
                    .frame(minHeight: 220, idealHeight: 320)
            }
            .padding(20)
            .onAppear {
                if selection == nil {
                    selection = model.activities.first?.id
                }
            }
            .onChange(of: model.activities.map(\.id)) { _, identifiers in
                if let selection, !identifiers.contains(selection) {
                    self.selection = identifiers.first
                }
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(entry.title, systemImage: entry.outcome.systemImage)
                            .font(.headline)
                            .foregroundStyle(entry.outcome.tint)
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .standard))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.detail)
                        .textSelection(.enabled)

                    if let command = entry.command {
                        outputSection("命令", text: "brew " + command.arguments.joined(separator: " "))
                        if !command.standardOutput.isEmpty {
                            outputSection("stdout", text: displayed(command.standardOutput))
                        }
                        if !command.standardError.isEmpty {
                            outputSection("stderr", text: displayed(command.standardError))
                        }
                        if command.standardOutputWasTruncated || command.standardErrorWasTruncated {
                            Label("进程输出超过保留上限，已截断。", systemImage: "scissors")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView("选择一条记录", systemImage: "sidebar.right")
        }
    }

    private var selectedEntry: ActivityEntry? {
        guard let selection else { return nil }
        return model.activities.first { $0.id == selection }
    }

    private func outputSection(_ title: String, text: String) -> some View {
        GroupBox(title) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }

    private func displayed(_ value: String) -> String {
        let limit = 100_000
        return value.count > limit ? String(value.prefix(limit)) + "\n… UI 显示已截断" : value
    }
}

private extension ActivityEntry.Outcome {
    var systemImage: String {
        switch self {
        case .started: "progress.indicator"
        case .succeeded: "checkmark.circle.fill"
        case .partiallySucceeded: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .started: .blue
        case .succeeded: .green
        case .partiallySucceeded: .orange
        case .failed: .red
        }
    }
}
