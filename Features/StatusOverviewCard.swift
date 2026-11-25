import SwiftUI

struct StatusMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let valueTint: Color?
    let statusDotColor: Color?
    let valueSystemImage: String?
    let valueSystemImageTint: Color
    let valueSystemImageHelp: LocalizedStringResource?
    let titleLink: URL?
    let titleLinkLabel: LocalizedStringResource?
    let detail: String?
    let detailTint: Color?
    let systemImage: String
    let brandAssetName: String?
    let tint: Color

    init(
        title: String,
        value: String,
        valueTint: Color? = nil,
        statusDotColor: Color? = nil,
        valueSystemImage: String? = nil,
        valueSystemImageTint: Color = .orange,
        valueSystemImageHelp: LocalizedStringResource? = nil,
        titleLink: URL? = nil,
        titleLinkLabel: LocalizedStringResource? = nil,
        detail: String? = nil,
        detailTint: Color? = nil,
        systemImage: String,
        brandAssetName: String? = nil,
        tint: Color
    ) {
        self.title = title
        self.value = value
        self.valueTint = valueTint
        self.statusDotColor = statusDotColor
        self.valueSystemImage = valueSystemImage
        self.valueSystemImageTint = valueSystemImageTint
        self.valueSystemImageHelp = valueSystemImageHelp
        self.titleLink = titleLink
        self.titleLinkLabel = titleLinkLabel
        self.detail = detail
        self.detailTint = detailTint
        self.systemImage = systemImage
        self.brandAssetName = brandAssetName
        self.tint = tint
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                LinkedTitle(title, destination: titleLink, linkLabel: titleLinkLabel, baseColor: .secondary)
                    .font(.callout.weight(.semibold))

                Spacer(minLength: 4)

                if let valueSystemImage {
                    Image(systemName: valueSystemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(valueSystemImageTint)
                        .accessibilityHidden(valueSystemImageHelp == nil)
                        .accessibilityLabel(valueSystemImageHelp.map { Text($0) } ?? Text(""))
                        .help(valueSystemImageHelp.map { Text($0) } ?? Text(""))
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 7) {
                    if let statusDotColor {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }

                    Text(value)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(valueTint ?? .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                }

                if let detail {
                    Text(detail)
                        .font(.caption.weight(detailTint == nil ? .regular : .semibold).monospacedDigit())
                        .foregroundStyle(detailTint ?? .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background {
            ZStack(alignment: .bottomTrailing) {
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.58 : 0.88))
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: tint.opacity(colorScheme == .dark ? 0.04 : 0.02), location: 0),
                            .init(color: tint.opacity(colorScheme == .dark ? 0.11 : 0.06), location: 0.55),
                            .init(color: tint.opacity(colorScheme == .dark ? 0.24 : 0.15), location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.fill(
                    RadialGradient(
                        colors: [
                            tint.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            .clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 4,
                        endRadius: 105
                    )
                )
                watermarkIcon
                    .offset(x: 6, y: 8)
                    .rotationEffect(.degrees(-8))
                    .opacity(colorScheme == .dark ? 0.26 : 0.20)
                    .accessibilityHidden(true)
            }
            .clipShape(shape)
        }
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                            tint.opacity(colorScheme == .dark ? 0.34 : 0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.035), radius: 5, x: 0, y: 1.5)
    }

    @ViewBuilder
    private var watermarkIcon: some View {
        if let brandAssetName {
            Image(brandAssetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
