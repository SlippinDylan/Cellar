import SwiftUI

struct TapTaskConfirmation: View {
    let plan: HomebrewActionPlan
    let cancel: () -> Void
    let confirm: () async -> String?

    @State private var isRunning = false
    @State private var hasFinished = false
    @State private var errorMessage: String?

    var body: some View {
        MaintenanceModalFrame(
            title: plan.action == .addTap ? LocalizedStringResource("Add Homebrew Tap") : LocalizedStringResource("Remove Homebrew Tap"),
            systemImage: plan.action == .addTap ? "plus.circle.fill" : "minus.circle.fill",
            tint: plan.action == .removeTap ? .red : .orange,
            width: 440
        ) {
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Text(errorMessage == nil ? LocalizedStringResource("Completed") : LocalizedStringResource("Operation Failed"))
                    .foregroundStyle(errorMessage == nil ? .green : .orange)
            } else if let name = plan.tapName {
                Text(verbatim: name).font(.subheadline.monospaced()).foregroundStyle(.secondary)
            }
        } content: {
            if isRunning {
                MaintenanceLoadingState(title: LocalizedStringResource("Running"))
            } else if hasFinished {
                HStack(alignment: errorMessage == nil ? .center : .top, spacing: 10) {
                    Image(systemName: errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(errorMessage == nil ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(errorMessage == nil ? LocalizedStringResource("All actions finished successfully.") : LocalizedStringResource("Operation Failed"))
                            .font(.body.weight(.medium))
                        if let errorMessage {
                            Text(verbatim: errorMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.action == .addTap ? LocalizedStringResource("Homebrew will download this Tap’s metadata and use it as a software source.") : LocalizedStringResource("Remove this Tap’s metadata. Installed software is checked again before removal."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !plan.associatedPackages.isEmpty {
                        Label("This Tap is required by installed software and cannot be removed.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        MaintenanceDetailWell(maxHeight: 200) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(plan.associatedPackages, id: \.self) { package in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(package.name).textSelection(.enabled)
                                        Text(CatalogProviderScope.homebrew(package.kind).cardTitle).font(.caption).foregroundStyle(.secondary)
                                    }.accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Button("OK", action: cancel)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(role: plan.action == .removeTap ? .destructive : nil) {
                    guard !isRunning else { return }
                    isRunning = true
                    Task {
                        errorMessage = await confirm()
                        isRunning = false
                        hasFinished = true
                    }
                } label: {
                    Text(plan.action == .addTap ? LocalizedStringResource("Add Tap") : LocalizedStringResource("Remove Tap"))
                }
                .buttonStyle(.glassProminent)
                .tint(plan.action == .removeTap ? .red : .blue)
                .disabled(!plan.canExecute)
            }
        }
        .interactiveDismissDisabled(isRunning)
    }
}
