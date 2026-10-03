import SwiftUI

struct ShellPlaceholderView: View {
    let destination: AppDestination

    var body: some View {
        ContentUnavailableView {
            Label { Text(destination.title) } icon: { Image(systemName: destination.systemImage) }
        } description: {
            Text("This page is not available yet.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
