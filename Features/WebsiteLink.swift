import SwiftUI

struct WebsiteLink: View {
    let destination: URL
    let title: LocalizedStringResource
    var showsTitle = false

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 6) {
                if showsTitle { Text(title).foregroundStyle(.blue) }
                Image(systemName: "arrow.turn.right.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text(title))
        .accessibilityHint("Opens in the default browser")
        .help(Text(title))
    }
}
