import AppKit
import SwiftUI

struct ToolbarCategoryPicker<Selection: CaseIterable & Hashable>: NSViewRepresentable {
    @Binding var selection: Selection
    let label: LocalizedStringResource
    let title: (Selection) -> LocalizedStringResource

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: Selection.allCases.map { String(localized: title($0)) },
                                         trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.selectCategory(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        control.setAccessibilityLabel(String(localized: label))
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (index, value) in Selection.allCases.enumerated() {
            control.setLabel(String(localized: title(value)), forSegment: index)
            control.setWidth(0, forSegment: index)
            if value == selection { control.selectedSegment = index }
        }
        control.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ToolbarCategoryPicker
        init(parent: ToolbarCategoryPicker) { self.parent = parent }

        @objc func selectCategory(_ sender: NSSegmentedControl) {
            let values = Array(Selection.allCases)
            guard values.indices.contains(sender.selectedSegment) else { return }
            parent.selection = values[sender.selectedSegment]
        }
    }
}

struct GlassCategoryPicker<Selection: CaseIterable & Hashable>: View {
    @Binding var selection: Selection
    let label: LocalizedStringResource
    let title: (Selection) -> LocalizedStringResource

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Selection.allCases), id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selection == option ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                }
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}
