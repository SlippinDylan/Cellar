import SwiftUI

enum HomebrewPackageFilter: String, CaseIterable, Identifiable {
    case all
    case formula
    case cask

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .formula: "Formula"
        case .cask: "Cask"
        }
    }

    func includes(_ kind: HomebrewPackageKind) -> Bool {
        switch self {
        case .all: true
        case .formula: kind == .formula
        case .cask: kind == .cask
        }
    }
}

struct HomebrewPageState<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder let content: (HomebrewSnapshot) -> Content

    var body: some View {
        if let status = model.homebrew {
            if !status.isInstalled {
                ContentUnavailableView(
                    "未安装 Homebrew",
                    systemImage: "mug",
                    description: Text("Cellar 不负责安装 Homebrew。安装后刷新即可读取状态。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = status.snapshot {
                content(snapshot)
            } else {
                ContentUnavailableView(
                    "Homebrew 状态不完整",
                    systemImage: "exclamationmark.triangle",
                    description: Text(homebrewLoadError(model) ?? "已找到 brew，但详细状态读取失败，请刷新后重试。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.isRefreshing {
            PageLoadingView(message: "正在读取 Homebrew 状态…")
        } else {
            ContentUnavailableView(
                "无法读取 Homebrew",
                systemImage: "mug",
                description: Text(homebrewLoadError(model) ?? "请刷新后重试")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct HomebrewPageHeader: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .blue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

struct HomebrewBusyButtonLabel: View {
    let title: String
    let workingTitle: String
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(isWorking ? workingTitle : title)
        }
    }
}

struct HomebrewEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HomebrewSectionErrorCard: View {
    let title: String
    let message: String

    var body: some View {
        StatusOverviewCard {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension HomebrewPackageKind {
    var displayName: String {
        switch self {
        case .formula: "Formula"
        case .cask: "Cask"
        }
    }
}

@MainActor
func homebrewLoadError(_ model: AppModel) -> String? {
    model.errorMessages.first(where: { $0.hasPrefix("Homebrew") })
}

func joinedVersions(_ versions: [String]) -> String {
    versions.isEmpty ? "—" : versions.joined(separator: ", ")
}
