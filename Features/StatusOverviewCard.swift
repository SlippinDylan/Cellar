import SwiftUI

struct StatusMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let valueSuffix: String?
    let valueSystemImage: String?
    let valueSystemImageTint: Color
    let titleLink: URL?
    let titleLinkLabel: LocalizedStringResource?
    let detail: String?
    let systemImage: String
    let brandAssetName: String?
    let assetSize: CGFloat
    let tint: Color
    let isStandaloneCard: Bool

    init(
        title: String,
        value: String,
        valueSuffix: String? = nil,
        valueSystemImage: String? = nil,
        valueSystemImageTint: Color = .orange,
        titleLink: URL? = nil,
        titleLinkLabel: LocalizedStringResource? = nil,
        detail: String? = nil,
        systemImage: String,
        brandAssetName: String? = nil,
        assetSize: CGFloat = 30,
        tint: Color,
        isStandaloneCard: Bool = false
    ) {
        self.title = title
        self.value = value
        self.valueSuffix = valueSuffix
        self.valueSystemImage = valueSystemImage
        self.valueSystemImageTint = valueSystemImageTint
        self.titleLink = titleLink
        self.titleLinkLabel = titleLinkLabel
        self.detail = detail
        self.systemImage = systemImage
        self.brandAssetName = brandAssetName
        self.assetSize = assetSize
        self.tint = tint
        self.isStandaloneCard = isStandaloneCard
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let brandAssetName {
                    Image(brandAssetName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: assetSize, height: assetSize)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 24))
                        .foregroundStyle(tint)
                }
            }
                .shadow(color: .black.opacity(isStandaloneCard ? 0.12 : 0), radius: 0.8, y: 0.7)
                .frame(width: isStandaloneCard ? 44 : 28, height: isStandaloneCard ? 44 : nil)
                .background {
                    if isStandaloneCard {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(.white)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(LinearGradient(colors: [tint.opacity(0.02), tint.opacity(0.06)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.12), radius: 4, y: 2)
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title)
                        .foregroundStyle(.secondary)

                    if let titleLink, let titleLinkLabel {
                        WebsiteLink(destination: titleLink, title: titleLinkLabel)
                    }
                }
                .font(.caption)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .lineLimit(isStandaloneCard ? 2 : 1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.middle)

                    if let valueSuffix {
                        Text(valueSuffix)
                            .font(.system(size: NSFont.systemFontSize - 1, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

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
        .frame(minHeight: isStandaloneCard ? 44 : nil)
        .padding(.horizontal, isStandaloneCard ? 14 : 0)
        .padding(.vertical, isStandaloneCard ? 10 : 0)
        .background {
            if isStandaloneCard {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35))
            }
        }
    }
}
