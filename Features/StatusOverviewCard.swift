import SwiftUI

struct StatusOverviewCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            content()
                .padding(.vertical, 4)
        }
    }
}

struct StatusMetric: View {
    let title: String
    let value: String
    let valueSystemImage: String?
    let valueSystemImageTint: Color
    let titleLink: URL?
    let titleLinkLabel: LocalizedStringResource?
    let detail: String?
    let systemImage: String
    let tint: Color

    init(
        title: String,
        value: String,
        valueSystemImage: String? = nil,
        valueSystemImageTint: Color = .orange,
        titleLink: URL? = nil,
        titleLinkLabel: LocalizedStringResource? = nil,
        detail: String? = nil,
        systemImage: String,
        tint: Color
    ) {
        self.title = title
        self.value = value
        self.valueSystemImage = valueSystemImage
        self.valueSystemImageTint = valueSystemImageTint
        self.titleLink = titleLink
        self.titleLinkLabel = titleLinkLabel
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
                HStack(spacing: 4) {
                    Text(title)
                        .foregroundStyle(.secondary)

                    if let titleLink, let titleLinkLabel {
                        WebsiteLink(destination: titleLink, title: titleLinkLabel)
                    }
                }
                .font(.caption)

                HStack(spacing: 6) {
                    Text(value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.middle)

                    if let valueSystemImage {
                        Image(systemName: valueSystemImage)
                            .foregroundStyle(valueSystemImageTint)
                            .accessibilityHidden(true)
                    }

                }
                .font(.headline)

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

struct OperationRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let actionTitle: String
    var role: ButtonRole?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button(actionTitle, role: role, action: action)
                .buttonStyle(.glass)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 10)
    }
}
