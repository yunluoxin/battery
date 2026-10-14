import Foundation
import Combine
import BatteryCore

/// The UI language, and the string table that goes with it.
///
/// Injected into the SwiftUI environment (see the root views) rather than read
/// through a global: a view that reads `l10n` in its `body` is subscribed to
/// `language`, so switching it re-renders open windows, the menu bar popover
/// and the settings panel in place — no relaunch.
///
/// Keys are the English text itself. A missing translation then degrades to
/// English rather than to a raw key in the UI, which is why the English table
/// can stay empty and why adding a language never risks a half-labelled screen.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    @Published private(set) var language: AppLanguage = .system

    /// The `.lproj` for the current language. Starts as `Bundle.main`, which
    /// resolves against the system language and is the right answer until
    /// `load(from:)` runs at launch.
    private var bundle: Bundle = .main

    private init() {}

    /// Adopt the persisted preference. Called once at launch, before any
    /// window exists, so the first frame a user sees is already localized.
    func load(from config: AppConfig) {
        apply(config.language)
    }

    /// Switch language. The caller is responsible for persisting it.
    func setLanguage(_ language: AppLanguage) {
        apply(language)
    }

    private func apply(_ language: AppLanguage) {
        self.language = language
        self.bundle = Self.bundle(for: language)
    }

    /// The translated string for `key`, or `key` itself when the current table
    /// has no entry for it.
    func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// `t` for a string with placeholders, which must be translated as whole
    /// format strings — a word order change in Chinese moves the placeholder,
    /// so translating only the fragments around it would break.
    ///
    /// The specifier has to match the argument's type or `String(format:)`
    /// traps at runtime: `%@` takes an *object* (a Swift `String` bridges to
    /// one, an `Int` does not — that is `%d`). Nothing in the UI reports a
    /// bad call site, so check the pair when adding a format string.
    func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    /// The `.lproj` directory for `language`, or `Bundle.main` when it is not
    /// in the bundle — the bare binary from `swift run` ships no `.lproj`, and
    /// `Bundle.main` then answers every key with itself.
    private static func bundle(for language: AppLanguage) -> Bundle {
        guard
            let lproj = AppLanguage.resolved(language).lproj,
            let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
            let bundle = Bundle(url: URL(fileURLWithPath: path))
        else { return .main }
        return bundle
    }
}

extension AppLanguage {
    /// Self-descriptive labels, the way every OS language picker does it: a
    /// language is listed in its own name so the option is recognisable before
    /// you switch to it. Only "System" needs translating, and it means
    /// something different on each Mac, so it goes through the table.
    @MainActor
    var displayName: String {
        switch self {
        case .system: Localization.shared.t("System")
        case .en: "English"
        case .zh: "简体中文"
        }
    }
}
