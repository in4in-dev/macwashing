import Foundation

/// Strings produced by the engine (titles of synthesized entries).
enum L10n {
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}
