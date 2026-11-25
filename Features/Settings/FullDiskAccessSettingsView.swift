import AppKit
import SwiftUI

struct FullDiskAccessSettingsView: View {
    @Environment(\.locale) private var locale
    @StateObject private var verification = ProtectedFileAccessVerification()
    @StateObject private var guide = FullDiskAccessGuide()
    @State private var verificationRequestID = UUID()
    @State private var openFailed = false

    var body: some View {
        SettingsSection(title: "Full Disk Access") {
            HStack(spacing: 24) {
                Text("Inspect protected application data during uninstallation.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    // Opening the settings pane does not establish whether access has been granted.
                    openFailed = !guide.open(locale: locale) {
                        verificationRequestID = UUID()
                    }
                } label: {
                    if verification.isVerified {
                        Label("Access Verified", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
                .tint(verification.isVerified ? Color.green : nil)
                .help("Open System Settings")
                .fixedSize()
            }
            .frame(minHeight: AppLayout.minimumDescribedRowHeight)
            if verification.result == .denied {
                Text("Access is blocked. Check Full Disk Access in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if verification.result == .unavailable {
                Text("Protected directory access could not be verified. Check Full Disk Access in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if openFailed {
                Label("System Settings could not be opened. Open Privacy & Security > Full Disk Access manually.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: verificationRequestID) { await verification.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guide.close()
            verificationRequestID = UUID()
        }
        .onDisappear {
            guide.close()
            verification.invalidate()
        }
    }
}
