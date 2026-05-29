import Foundation
import SwiftUI

/// The languages WallPics ships translations for. `nil` code = follow the system.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    case spanish = "es"
    case chineseSimplified = "zh-Hans"
    case german = "de"
    case french = "fr"
    case japanese = "ja"
    case portugueseBrazil = "pt-BR"

    var id: String { rawValue }

    /// Endonym (shown in its own language, the standard for language pickers).
    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .spanish: return "Español"
        case .chineseSimplified: return "简体中文"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .japanese: return "日本語"
        case .portugueseBrazil: return "Português (Brasil)"
        }
    }
}

@MainActor
enum LanguageController {
    private static let appleLanguagesKey = "AppleLanguages"

    /// Resolve the locale for the current session — the chosen language, or the system default.
    static func locale(for code: String?) -> Locale {
        guard let code, !code.isEmpty else { return .autoupdatingCurrent }
        return Locale(identifier: code)
    }

    /// Persist the choice for AppKit/system pieces (menus) and future launches. SwiftUI views
    /// update live via the `\.locale` environment; AppKit chrome picks it up on next launch.
    static func apply(_ code: String?) {
        let defaults = UserDefaults.standard
        if let code, !code.isEmpty {
            defaults.set([code], forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey) // back to system order
        }
    }
}
