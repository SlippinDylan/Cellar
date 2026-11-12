import AppKit
import SwiftUI

struct AboutView: View {
    @ObservedObject var updateController: ApplicationUpdateController

    private var version: String {
        guard let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            preconditionFailure("The app bundle must include version metadata")
        }
        return "\(marketing) (\(build))"
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 24) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 128, height: 128)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("Cellar").font(.system(size: 32, weight: .bold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                    Button("Check for Updates…") { updateController.checkForUpdates() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(!updateController.canCheckForUpdates)
                    Text("Copyright © 2026 SlippinDylan Studio")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - AppLayout.spacing * 2))
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)
        }
    }
}
