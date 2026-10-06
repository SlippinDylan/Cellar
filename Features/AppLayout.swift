import SwiftUI

enum AppLayout {
    static let spacing: CGFloat = 16
    static let cardSpacing: CGFloat = 8
}

struct AppFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.cardSpacing) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: AppLayout.spacing) {
                        if !section.header.isEmpty {
                            HStack { section.header }
                                .font(.headline)
                        }
                        GroupBox {
                            Form { section.content }
                                .formStyle(.columns)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !section.footer.isEmpty {
                            VStack(alignment: .leading) { section.footer }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(AppLayout.spacing, for: .scrollContent)
    }
}
