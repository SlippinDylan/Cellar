import AppKit
import Combine
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
        let (defaults, suiteName) = try makeDefaults()
        XCTAssertEqual(ApplicationLanguage.allCases.map(\.rawValue), ["system", "en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es"])
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        defaults.set("unsupported", forKey: ApplicationLanguage.preferenceKey)
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        let store = OperationStore()
        let relaunch = ApplicationRelaunchController(operationStore: store, defaults: defaults, defaultsDomainName: suiteName, terminateApplication: {
            XCTFail("Settings construction must not terminate the app")
        })
        let runner = ProcessRunner()
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarSettingsConstruction-\(UUID())")
        let resolver = NodeEnvironmentResolver(homeDirectory: root)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
                                         shellClient: ShellManagerClient(runner: runner, environmentResolver: ShellEnvironmentResolver(homeDirectory: root)),
                                         environmentResolver: resolver)
        let model = AppModel(service: service, operationStore: store)
        let settings = SettingsView(model: model,
                                    relaunchController: relaunch)
        XCTAssertTrue(settings.model === model)
        XCTAssertTrue(settings.operationStore === model.operationStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
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
        let (defaults, suiteName) = try makeDefaults()
        let store = OperationStore()
        let id = store.begin()
        defer { store.end(id) }
        var terminationCount = 0
        let controller = ApplicationRelaunchController(operationStore: store, defaults: defaults, defaultsDomainName: suiteName, terminateApplication: { terminationCount += 1 })
        XCTAssertFalse(controller.changeLanguage(.english))
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        XCTAssertEqual(terminationCount, 0)
        XCTAssertFalse(controller.consumeRelaunchRequest())
    }

    func testLanguageChangePersistsBeforeOneControlledTermination() throws {
        let (defaults, suiteName) = try makeDefaults()
        var terminationCount = 0
        let controller = ApplicationRelaunchController(operationStore: OperationStore(), defaults: defaults, defaultsDomainName: suiteName, terminateApplication: {
            XCTAssertEqual(defaults.stringArray(forKey: ApplicationLanguage.appleLanguagesKey), ["zh-Hant"])
            terminationCount += 1
        })
        XCTAssertTrue(controller.changeLanguage(.traditionalChinese))
        XCTAssertFalse(controller.changeLanguage(.english))
        XCTAssertEqual(terminationCount, 1)
        XCTAssertTrue(controller.consumeRelaunchRequest())
        XCTAssertFalse(controller.consumeRelaunchRequest())
        XCTAssertEqual(controller.selectedLanguage, .traditionalChinese)
        XCTAssertEqual(defaults.stringArray(forKey: ApplicationLanguage.appleLanguagesKey), ["zh-Hant"])
    }

    func testOrdinaryTerminationDoesNotReopenAndRelaunchReopensOnce() throws {
        let (defaults, suiteName) = try makeDefaults()
        var reopenCount = 0
        let controller = ApplicationRelaunchController(operationStore: OperationStore(), defaults: defaults, defaultsDomainName: suiteName, terminateApplication: {})
        let delegate = AppDelegate(operationStore: OperationStore(), relaunchController: controller, reopenApplication: { reopenCount += 1 })
        let notification = Notification(name: NSApplication.willTerminateNotification)
        delegate.applicationWillTerminate(notification)
        XCTAssertEqual(reopenCount, 0)
        XCTAssertTrue(controller.changeLanguage(.english))
        delegate.applicationWillTerminate(notification)
        delegate.applicationWillTerminate(notification)
        XCTAssertEqual(reopenCount, 1)
    }

    func testRefusedTerminationClearsPendingRelaunch() throws {
        let (defaults, suiteName) = try makeDefaults()
        let store = OperationStore()
        var terminationCount = 0
        var reopenCount = 0
        let controller = ApplicationRelaunchController(operationStore: store, defaults: defaults, defaultsDomainName: suiteName, terminateApplication: { terminationCount += 1 })
        let delegate = AppDelegate(operationStore: store, relaunchController: controller, reopenApplication: { reopenCount += 1 })
        var settingsSelection = controller.selectedLanguage
        let observation = controller.$selectedLanguage.sink { settingsSelection = $0 }
        defer { observation.cancel() }
        XCTAssertTrue(controller.changeLanguage(.english))
        XCTAssertEqual(settingsSelection, .english)
        let id = store.begin()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[ApplicationLanguage.preferenceKey])
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[ApplicationLanguage.appleLanguagesKey])
        XCTAssertEqual(ApplicationLanguage.selected(in: defaults), .system)
        XCTAssertEqual(controller.selectedLanguage, .system)
        XCTAssertEqual(settingsSelection, .system)
        XCTAssertFalse(controller.changeLanguage(.english))
        XCTAssertEqual(terminationCount, 1)
        store.end(id)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(reopenCount, 0)
        XCTAssertTrue(controller.changeLanguage(.english))
        XCTAssertEqual(settingsSelection, .english)
        XCTAssertEqual(terminationCount, 2)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(reopenCount, 1)
        XCTAssertFalse(controller.changeLanguage(.english))
        XCTAssertEqual(terminationCount, 2)
    }

    func testRefusedTerminationRestoresExactExplicitOverride() throws {
        let (defaults, suiteName) = try makeDefaults()
        defaults.set(ApplicationLanguage.english.rawValue, forKey: ApplicationLanguage.preferenceKey)
        defaults.set(["en", "fr"], forKey: ApplicationLanguage.appleLanguagesKey)
        let store = OperationStore()
        let controller = ApplicationRelaunchController(operationStore: store, defaults: defaults, defaultsDomainName: suiteName, terminateApplication: {})
        let delegate = AppDelegate(operationStore: store, relaunchController: controller, reopenApplication: {
            XCTFail("A refused termination must not reopen the app")
        })
        var settingsSelection = controller.selectedLanguage
        let observation = controller.$selectedLanguage.sink { settingsSelection = $0 }
        defer { observation.cancel() }
        XCTAssertTrue(controller.changeLanguage(.system))
        XCTAssertEqual(settingsSelection, .system)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[ApplicationLanguage.appleLanguagesKey])
        let id = store.begin()
        defer { store.end(id) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?[ApplicationLanguage.preferenceKey] as? String, "en")
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?[ApplicationLanguage.appleLanguagesKey] as? [String], ["en", "fr"])
        XCTAssertEqual(controller.selectedLanguage, .english)
        XCTAssertEqual(settingsSelection, .english)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}
