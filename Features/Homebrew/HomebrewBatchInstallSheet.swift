import SwiftUI

struct HomebrewBatchInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    @State private var kind: HomebrewPackageKind = .formula
    @State private var source = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量安装")
                        .font(.title3.weight(.semibold))
                    Text("一行一个名称；Formula 与 Cask 分别生成独立计划。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("类型", selection: $kind) {
                        Text("Formula").tag(HomebrewPackageKind.formula)
                        Text("Cask").tag(HomebrewPackageKind.cask)
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: $source)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if source.isEmpty {
                                Text("wget\nfd\nripgrep")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(14)
                                    .allowsHitTesting(false)
                            }
                        }

                    Text("最多 100 项。空行会忽略，重复项只保留第一次出现。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(minWidth: 360)

                GroupBox("安装预览") {
                    if packageNames.isEmpty {
                        ContentUnavailableView("尚未输入", systemImage: "list.bullet.clipboard")
                    } else {
                        List(packageNames, id: \.self) { name in
                            Label(name, systemImage: kind == .formula ? "shippingbox" : "app")
                        }
                        .listStyle(.inset)
                    }
                }
                .padding(20)
                .frame(minWidth: 300)
            }

            Divider()
            HStack {
                if duplicateCount > 0 {
                    Label("已去除 \(duplicateCount) 个重复项", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("为 \(packageNames.count) 项生成计划") { preparePlan() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(packageNames.isEmpty || packageNames.count > 100 || model.isBusy)
            }
            .padding(20)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 600)
    }

    private var rawNames: [String] {
        source
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var packageNames: [String] {
        var seen = Set<String>()
        return rawNames.filter { seen.insert($0).inserted }
    }

    private var duplicateCount: Int { rawNames.count - packageNames.count }

    private func preparePlan() {
        let identities = packageNames.map { HomebrewPackageIdentity(name: $0, kind: kind) }
        guard !identities.isEmpty, identities.count <= 100 else { return }
        dismiss()
        Task { await model.prepareHomebrewInstall(identities) }
    }
}
