import Foundation

enum ApplicationLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    static let preferenceKey = "application.language"
    static let appleLanguagesKey = "AppleLanguages"
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("Follow System")
        case .english: LocalizedStringResource("English")
        case .simplifiedChinese: LocalizedStringResource("简体中文")
        case .traditionalChinese: LocalizedStringResource("繁體中文")
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    @discardableResult
    static func select(_ language: Self, in defaults: UserDefaults = .standard) -> Bool {
        guard selected(in: defaults) != language else { return false }
        defaults.set(language.rawValue, forKey: preferenceKey)
        switch language {
        case .system: defaults.removeObject(forKey: appleLanguagesKey)
        case .english, .simplifiedChinese, .traditionalChinese:
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
        return true
    }
}
