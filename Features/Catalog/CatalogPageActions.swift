import SwiftUI

private struct CatalogSearchActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct DiscoverBatchActionKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var catalogSearchAction: (() -> Void)? {
        get { self[CatalogSearchActionKey.self] }
        set { self[CatalogSearchActionKey.self] = newValue }
    }

    var discoverBatchAction: (() -> Void)? {
        get { self[DiscoverBatchActionKey.self] }
        set { self[DiscoverBatchActionKey.self] = newValue }
    }
}
