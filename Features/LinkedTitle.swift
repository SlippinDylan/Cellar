import SwiftUI

struct LinkedTitle: View {
    let text: Text
    let destination: URL?
    let linkLabel: LocalizedStringResource?
    let baseColor: Color
    @State private var isHovered = false

    init(
        _ title: String,
        destination: URL? = nil,
        linkLabel: LocalizedStringResource? = nil,
        baseColor: Color = .primary
    ) {
        self.text = Text(verbatim: title)
        self.destination = destination
        self.linkLabel = linkLabel
        self.baseColor = baseColor
    }

    init(
        _ title: LocalizedStringResource,
        destination: URL? = nil,
        linkLabel: LocalizedStringResource? = nil,
        baseColor: Color = .primary
    ) {
        self.text = Text(title)
        self.destination = destination
        self.linkLabel = linkLabel
        self.baseColor = baseColor
    }

    var body: some View {
        if let destination {
            Link(destination: destination) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    text
                        .underline(isHovered)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isHovered {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.blue)
                            .offset(y: -0.5)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(isHovered ? Color.blue : baseColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityLabel(linkLabel.map { Text($0) } ?? text)
            .accessibilityHint("Opens in the default browser")
            .help(linkLabel.map { Text($0) } ?? text)
        } else {
            text
                .foregroundStyle(baseColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
