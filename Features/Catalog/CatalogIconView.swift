import AppKit
import SwiftUI

struct CatalogIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: CatalogCardState
    @State private var localImage: CGImage?
    @State private var remoteImage: NSImage?

    var body: some View {
        Group {
            if let localImage {
                Image(decorative: localImage, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.14), radius: 2.5, x: 0, y: 1)
            } else if let remoteImage {
                Image(nsImage: remoteImage)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.14), radius: 2.5, x: 0, y: 1)
            } else {
                fallbackIcon
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
        .task(id: state.icon) {
            switch state.icon {
            case .placeholder:
                localImage = nil
                remoteImage = nil
            case .remote:
                let data = await CatalogIconStore.shared.data(for: state.icon)
                guard !Task.isCancelled else { return }
                localImage = nil
                remoteImage = data.flatMap(NSImage.init(data:))
            case .localApp(let candidates, let fallback):
                if let local = await CatalogIconStore.shared.localAppIcon(for: candidates) {
                    guard !Task.isCancelled else { return }
                    localImage = local
                    remoteImage = nil
                    return
                }
                if let fallback {
                    let data = await CatalogIconStore.shared.data(for: .remote(fallback))
                    guard !Task.isCancelled else { return }
                    localImage = nil
                    remoteImage = data.flatMap(NSImage.init(data:))
                } else {
                    localImage = nil
                    remoteImage = nil
                }
            }
        }
    }

    private var fallbackIcon: some View {
        // macOS app icons use an 824/1024 (~80.5%) squircle inside a transparent canvas.
        // Matching that inset (45 pt inside 56 pt) keeps fallback tiles optically identical to real app icons.
        let shape = RoundedRectangle(cornerRadius: 10.5, style: .continuous)
        return Group {
            switch state.identity.providerScope {
            case .homebrewFormula:
                formulaIcon(in: shape)
            case .npm:
                npmIcon(in: shape)
            case .homebrewCask:
                caskMonogramIcon(in: shape)
            }
        }
        .frame(width: 45, height: 45)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.11), radius: 2.2, x: 0, y: 1)
    }

    private func formulaIcon(in shape: RoundedRectangle) -> some View {
        let isDark = colorScheme == .dark
        return shape
            .fill(
                LinearGradient(
                    colors: isDark
                        ? [Color(red: 0.25, green: 0.27, blue: 0.31), Color(red: 0.14, green: 0.15, blue: 0.18)]
                        : [Color(red: 0.27, green: 0.29, blue: 0.34), Color(red: 0.15, green: 0.16, blue: 0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                HStack(alignment: .bottom, spacing: 2.5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(red: 0.45, green: 0.85, blue: 0.56))
                        .frame(width: 8, height: 2.2)
                        .offset(y: -1)
                }
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(isDark ? 0.22 : 0.28), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private func npmIcon(in shape: RoundedRectangle) -> some View {
        let isDark = colorScheme == .dark
        return shape
            .fill(
                LinearGradient(
                    colors: isDark
                        ? [Color(red: 0.20, green: 0.21, blue: 0.24), Color(red: 0.14, green: 0.15, blue: 0.18)]
                        : [Color(red: 1.00, green: 1.00, blue: 1.00), Color(red: 0.94, green: 0.95, blue: 0.97)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: isDark
                                ? [Color(red: 0.78, green: 0.80, blue: 0.84), Color(red: 0.56, green: 0.59, blue: 0.65)]
                                : [Color(red: 0.36, green: 0.40, blue: 0.47), Color(red: 0.24, green: 0.27, blue: 0.33)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                shape
                    .strokeBorder(
                        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08),
                        lineWidth: 0.75
                    )
            }
    }

    private func caskMonogramIcon(in shape: RoundedRectangle) -> some View {
        let isDark = colorScheme == .dark
        let accent = isDark ? Color(red: 0.42, green: 0.72, blue: 1.00) : Color(red: 0.10, green: 0.47, blue: 0.88)
        return shape
            .fill(
                LinearGradient(
                    colors: isDark
                        ? [Color(red: 0.14, green: 0.21, blue: 0.30), Color(red: 0.10, green: 0.15, blue: 0.22)]
                        : [Color(red: 0.94, green: 0.97, blue: 1.00), Color(red: 0.86, green: 0.93, blue: 0.99)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text(String(state.displayName.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .overlay {
                shape
                    .strokeBorder(accent.opacity(isDark ? 0.28 : 0.18), lineWidth: 0.75)
            }
    }
}
