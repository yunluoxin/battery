import Foundation

/// The GUI app's own version, as shipped in its bundle's Info.plist.
///
/// `build.sh` writes `APP_VERSION` into `CFBundleShortVersionString`, so this
/// reads back exactly the number that went into the release — the About panel
/// cannot drift from the DMG filename the way a separately hardcoded constant
/// would.
///
/// App-only by design: the helper links this target's sibling modules but has
/// no UI, so nothing outside the About panel should ever read this.
enum AppVersion {
    /// The marketing version (`CFBundleShortVersionString`), e.g. "1.0.0".
    ///
    /// Falls back to a placeholder rather than an empty string: the bare binary
    /// from `swift run` has no Info.plist at all, and a blank row in About reads
    /// as a bug in the app rather than as a missing bundle.
    static var current: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version, !version.isEmpty else { return "—" }
        return version
    }
}
