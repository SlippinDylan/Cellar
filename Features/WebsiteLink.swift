import SwiftUI

struct WebsiteLink: View {
    let destination: URL
    let title: LocalizedStringResource

    var body: some View {
        Link(destination: destination) {
            Image(systemName: "safari")
                .imageScale(.medium)
                .foregroundStyle(.blue)
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text(title))
        .accessibilityHint("Opens in the default browser")
        .help(Text(title))
    }
}
