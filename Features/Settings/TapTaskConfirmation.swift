import SwiftUI

struct TapTaskConfirmation: View {
    let plan: HomebrewActionPlan
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan.action == .addTap ? LocalizedStringResource("Add Homebrew Tap") : LocalizedStringResource("Remove Homebrew Tap")).font(.title2.bold())
            if let name = plan.tapName { Text(name).font(.body.monospaced()).textSelection(.enabled) }
            Text(plan.action == .addTap ? LocalizedStringResource("Homebrew will download this Tap’s metadata and use it as a software source.") : LocalizedStringResource("Remove this Tap’s metadata. Installed software is checked again before removal."))
            if !plan.associatedPackages.isEmpty {
                Text("This Tap is required by installed software and cannot be removed.")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.associatedPackages, id: \.self) { package in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(package.name).textSelection(.enabled)
                                Text(CatalogProviderScope.homebrew(package.kind).cardTitle).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(role: plan.action == .removeTap ? .destructive : nil) { confirm() } label: { Text(plan.action == .addTap ? LocalizedStringResource("Add Tap") : LocalizedStringResource("Remove Tap")) }.disabled(!plan.canExecute)
            }
        }.padding(24).constrainedSheetWidth(500)
    }
}
