import SwiftUI

private struct CatalogSearchActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct BatchInstallActionKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var catalogSearchAction: (() -> Void)? {
        get { self[CatalogSearchActionKey.self] }
        set { self[CatalogSearchActionKey.self] = newValue }
    }

    var batchInstallAction: (() -> Void)? {
        get { self[BatchInstallActionKey.self] }
        set { self[BatchInstallActionKey.self] = newValue }
    }
}
