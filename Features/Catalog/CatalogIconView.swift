import SwiftUI

struct CatalogIconView: View {
    let state: CatalogCardState
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        if state.identity.providerScope == .homebrewCask {
                            Text(String(state.displayName.prefix(1)).uppercased())
                                .font(.title2.weight(.semibold))
                        } else {
                            Image(systemName: state.identity.providerScope == .npm ? "shippingbox" : "terminal")
                                .font(.title2)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
        .task(id: state.icon) {
            image = nil
            let data = await CatalogIconStore.shared.data(for: state.icon)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
