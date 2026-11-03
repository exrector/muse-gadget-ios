import Foundation
import SwiftUI

/// Runtime localization for text that passes through models before reaching SwiftUI.
enum PalL10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func key(_ value: String) -> LocalizedStringKey {
        LocalizedStringKey(value)
    }
}
