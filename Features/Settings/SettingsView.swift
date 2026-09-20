import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "通用"
        case about = "关于"
        var id: Self { self }
    }

    let updateController: ApplicationUpdateController
    @State private var pane: Pane = .general
    @Namespace private var paneNamespace

    var body: some View {
        selectedPane
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    paneSelector
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch pane {
        case .general: generalPane
        case .about: AboutView(updateController: updateController)
        }
    }

    private var paneSelector: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Pane.allCases) { item in
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { pane = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.callout.weight(pane == item ? .semibold : .medium))
                            .padding(.horizontal, 16)
                            .frame(minWidth: 80, minHeight: 32)
                            .contentShape(Capsule())
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(pane == item ? Color.white : Color.primary)
                        .background {
                            if pane == item {
                                Color.clear
                                    .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
                                    .glassEffectID("settings-pane-selection", in: paneNamespace)
                            }
                        }
                        .accessibilityAddTraits(pane == item ? .isSelected : [])
                }
            }
            .padding(3)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .frame(maxWidth: 200)
    }

    private var generalPane: some View {
        Form {
            Section("运行方式") {
                LabeledContent("应用类型", value: "普通前台窗口")
                LabeledContent("最低系统", value: "macOS 26.0")
                LabeledContent("架构", value: "Apple Silicon")
            }
            Section("数据") {
                LabeledContent("Manager 运行副本", value: "~/Library/Application Support/Cellar/Managers")
                Text("操作记录只保留在本次 App 会话。Cellar 不包含账户、遥测或自己的服务端。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
    }
}

struct AboutView: View {
    let updateController: ApplicationUpdateController

    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)

            VStack(spacing: 8) {
                Text("Cellar").font(.largeTitle.bold())
                Text("版本 \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("检查更新…") { updateController.checkForUpdates() }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(!updateController.canCheckForUpdates)

            Text("Copyright © 2026 SlippinDylan Studio")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
