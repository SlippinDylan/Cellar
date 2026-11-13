import Foundation

enum ApplicationLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"

    static let preferenceKey = "application.language"
    static let appleLanguagesKey = "AppleLanguages"
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("Follow System")
        case .english: LocalizedStringResource("English")
        case .simplifiedChinese: LocalizedStringResource("简体中文")
        case .traditionalChinese: LocalizedStringResource("繁體中文")
        case .japanese: LocalizedStringResource("日本語")
        case .korean: LocalizedStringResource("한국어")
        case .german: LocalizedStringResource("Deutsch")
        case .french: LocalizedStringResource("Français")
        case .spanish: LocalizedStringResource("Español")
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
        case .english, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .german, .french, .spanish:
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
        return true
    }
}
