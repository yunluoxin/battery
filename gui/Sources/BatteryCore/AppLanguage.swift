import Foundation

/// UI language chosen in Settings → Appearance.
///
/// Lives in BatteryCore rather than the app target because it is part of
/// `AppConfig`, which BatteryCore persists. It carries no strings itself: the
/// translations ship in the app bundle's `.lproj` directories, so the helper —
/// which links this module but has no UI — never loads them.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case en
    case zh

    /// The `.lproj` that backs this choice, or nil when the table is missing
    /// from the bundle (e.g. running the bare binary from `swift run`, which
    /// has no Resources at all) and the caller should fall back to the key.
    public var lproj: String? {
        switch self {
        case .system: nil
        case .en: "en"
        case .zh: "zh-Hans"
        }
    }

    /// The concrete language `.system` stands for on this Mac.
    ///
    /// Resolved from `Locale.preferredLanguages` instead of asking
    /// `Bundle.main`, because Bundle's own matching would hand a zh-Hant user
    /// an absent table and silently fall back to English. Only Simplified
    /// Chinese ships today, so both scripts resolve to it.
    /// `languages` is injectable so the mapping can be tested without editing
    /// the Mac's own language list.
    public static func resolved(_ language: AppLanguage = .system,
                                languages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard language == .system else { return language }
        for preferred in languages {
            let code = preferred.lowercased()
            if code.hasPrefix("zh") { return .zh }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }
}
