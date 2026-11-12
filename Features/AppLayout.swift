import SwiftUI

enum AppLayout {
    static let spacing: CGFloat = 16
    static let cardSpacing: CGFloat = 8
    static let minimumInfoRowHeight: CGFloat = 32
    static let minimumControlRowHeight: CGFloat = 40
    static let minimumDescribedRowHeight: CGFloat = 52
}

struct SettingsPage<Content: View>: View {
    var fillsViewport = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: fillsViewport ? max(0, geometry.size.height - AppLayout.spacing * 2) : nil,
                       alignment: .topLeading)
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringResource
    var website: URL? = nil
    var websiteTitle: LocalizedStringResource = "Official Website"
    var detail: String? = nil
    var action: SettingsSectionAction? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let website {
                    WebsiteLink(destination: website, title: websiteTitle)
                        .font(.caption)
                }
                if detail != nil || action != nil { Spacer(minLength: 12) }
                if let detail {
                    Text(verbatim: detail).font(.callout).foregroundStyle(.secondary)
                }
                if let action {
                    Button(action.title, action: action.perform)
                        .disabled(!action.isEnabled)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SettingsSectionAction {
    let title: LocalizedStringResource
    let isEnabled: Bool
    let perform: () -> Void
}

struct SettingsTextField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(verbatim: prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }
}
