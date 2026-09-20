import SwiftUI

struct StatusOverviewCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(tint.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(tint.opacity(0.1), lineWidth: 1)
            }
    }
}

struct StatusMetric: View {
    let title: String
    let value: String
    let detail: String?
    let systemImage: String
    let tint: Color

    init(
        title: String,
        value: String,
        detail: String? = nil,
        systemImage: String,
        tint: Color
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusMetricDivider: View {
    var body: some View {
        Divider()
            .frame(height: 48)
            .padding(.horizontal, 16)
    }
}

struct PageLoadingView: View {
    let message: String

    var body: some View {
        ProgressView(message)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct FeaturePlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("功能入口已预留，当前版本尚未实现")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
