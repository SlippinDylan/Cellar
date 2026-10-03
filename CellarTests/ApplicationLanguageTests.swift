import AppKit
import XCTest
@testable import Cellar

@MainActor
final class ApplicationLanguageTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "Cellar.ApplicationLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return (defaults, suiteName)
    }

    func testDefaultsAndSupportedValues() throws {
        let (defaults, _) = try makeDefaults()
        XCTAssertEqual(ApplicationLanguage.allCases.map(\.rawValue), ["system", "en", "zh-Hans", "zh-Hant"])
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        defaults.set("unsupported", forKey: ApplicationLanguage.preferenceKey)
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        let store = OperationStore()
        let relaunch = ApplicationRelaunchController(operationStore: store, terminateApplication: {
            XCTFail("Settings construction must not terminate the app")
        })
        _ = SettingsView(updateController: ApplicationUpdateController(updaterEnabled: false),
                         relaunchController: relaunch, operationStore: store, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ApplicationLanguage.preferenceKey), "unsupported")
        XCTAssertNil(defaults.string(forKey: "settings.pane"))
    }

    func testExplicitLanguagesPersistAndSystemRemovesOnlyAppOverride() throws {
        let (defaults, suiteName) = try makeDefaults()
        for language in ApplicationLanguage.allCases where language != .system {
            XCTAssertTrue(ApplicationLanguage.select(language, in: defaults))
            XCTAssertEqual(ApplicationLanguage.selected(in: defaults), language)
            XCTAssertEqual(defaults.stringArray(forKey: ApplicationLanguage.appleLanguagesKey), [language.rawValue])
        }
        XCTAssertTrue(ApplicationLanguage.select(.system, in: defaults))
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[ApplicationLanguage.appleLanguagesKey])
        XCTAssertFalse(ApplicationLanguage.select(.system, in: defaults))
    }

    func testBusyLanguageChangeDoesNotPersistOrTerminate() throws {
        let (defaults, _) = try makeDefaults()
        let store = OperationStore()
        let id = store.begin()
        defer { store.end(id) }
        var terminationCount = 0
        let controller = ApplicationRelaunchController(operationStore: store, terminateApplication: { terminationCount += 1 })
        XCTAssertFalse(controller.changeLanguage(.english, in: defaults))
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        XCTAssertEqual(terminationCount, 0)
        XCTAssertFalse(controller.consumeRelaunchRequest())
    }

    func testLanguageChangePersistsBeforeOneControlledTermination() throws {
        let (defaults, _) = try makeDefaults()
        var terminationCount = 0
        let controller = ApplicationRelaunchController(operationStore: OperationStore(), terminateApplication: {
            XCTAssertEqual(defaults.stringArray(forKey: ApplicationLanguage.appleLanguagesKey), ["zh-Hant"])
            terminationCount += 1
        })
        XCTAssertTrue(controller.changeLanguage(.traditionalChinese, in: defaults))
        XCTAssertFalse(controller.changeLanguage(.english, in: defaults))
        XCTAssertEqual(terminationCount, 1)
        XCTAssertTrue(controller.consumeRelaunchRequest())
        XCTAssertFalse(controller.consumeRelaunchRequest())
    }

    func testOrdinaryTerminationDoesNotReopenAndRelaunchReopensOnce() throws {
        let (defaults, _) = try makeDefaults()
        var reopenCount = 0
        let controller = ApplicationRelaunchController(operationStore: OperationStore(), terminateApplication: {})
        let delegate = AppDelegate(operationStore: OperationStore(), relaunchController: controller, reopenApplication: { reopenCount += 1 })
        let notification = Notification(name: NSApplication.willTerminateNotification)
        delegate.applicationWillTerminate(notification)
        XCTAssertEqual(reopenCount, 0)
        XCTAssertTrue(controller.changeLanguage(.english, in: defaults))
        delegate.applicationWillTerminate(notification)
        delegate.applicationWillTerminate(notification)
        XCTAssertEqual(reopenCount, 1)
    }

    func testRefusedTerminationClearsPendingRelaunch() throws {
        let (defaults, _) = try makeDefaults()
        let store = OperationStore()
        var reopenCount = 0
        let controller = ApplicationRelaunchController(operationStore: store, terminateApplication: {})
        let delegate = AppDelegate(operationStore: store, relaunchController: controller, reopenApplication: { reopenCount += 1 })
        XCTAssertTrue(controller.changeLanguage(.english, in: defaults))
        let id = store.begin()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        store.end(id)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(reopenCount, 0)
    }
}
