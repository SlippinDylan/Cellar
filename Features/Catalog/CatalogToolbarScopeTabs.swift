import AppKit
import SwiftUI

enum CatalogScopeTab: Hashable {
    case all, brew, brewAll, formula, cask, npm

    var isBrew: Bool {
        switch self {
        case .brew, .brewAll, .formula, .cask: true
        case .all, .npm: false
        }
    }

    var scope: CatalogScope {
        switch self {
        case .all: .all
        case .brew, .brewAll, .formula, .cask: .homebrew
        case .npm: .npm
        }
    }

    var subtype: LibraryHomebrewSubtype {
        switch self {
        case .formula: .formula
        case .cask: .cask
        case .all, .brew, .brewAll, .npm: .all
        }
    }
}

struct CatalogScopeTabActions {
    let selected: CatalogScopeTab
    let select: (CatalogScopeTab) -> Void
}

struct CatalogToolbarScopeTabs: NSViewRepresentable {
    let actions: CatalogScopeTabActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions, tabs: tabs)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: tabs.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectTab(_:))
        )
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        update(control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        update(control, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    private var tabs: [CatalogScopeTab] {
        actions.selected.isBrew ? [.all, .brew, .brewAll, .formula, .cask, .npm] : [.all, .brew, .npm]
    }

    private func update(_ control: NSSegmentedControl, coordinator: Coordinator) {
        coordinator.actions = actions
        coordinator.tabs = tabs
        control.segmentCount = tabs.count
        for (index, tab) in tabs.enumerated() {
            control.setLabel(tab.title, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectedSegment = tabs.firstIndex(of: actions.selected) ?? -1
        control.invalidateIntrinsicContentSize()
    }

    @MainActor final class Coordinator: NSObject {
        var actions: CatalogScopeTabActions
        var tabs: [CatalogScopeTab]

        init(actions: CatalogScopeTabActions, tabs: [CatalogScopeTab]) {
            self.actions = actions
            self.tabs = tabs
        }

        @objc func selectTab(_ sender: NSSegmentedControl) {
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            actions.select(tabs[sender.selectedSegment])
        }
    }
}

struct LibraryToolbarUpdateFilter: NSViewRepresentable {
    @Binding var selection: LibraryUpdateFilter

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [String(localized: "Pending Updates")], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.toggleFilter(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        control.setAccessibilityLabel(String(localized: "Update Status"))
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.setSelected(selection == .pendingUpdates, forSegment: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    @MainActor final class Coordinator: NSObject {
        var parent: LibraryToolbarUpdateFilter
        init(parent: LibraryToolbarUpdateFilter) { self.parent = parent }

        @objc func toggleFilter(_ sender: NSSegmentedControl) {
            parent.selection = parent.selection == .pendingUpdates ? .all : .pendingUpdates
            sender.setSelected(parent.selection == .pendingUpdates, forSegment: 0)
        }
    }
}

private extension CatalogScopeTab {
    var title: String {
        switch self {
        case .all, .brewAll: String(localized: "All")
        case .brew: String(localized: "Brew")
        case .formula: String(localized: "Formula")
        case .cask: String(localized: "Cask")
        case .npm: String(localized: "NPM")
        }
    }
}
