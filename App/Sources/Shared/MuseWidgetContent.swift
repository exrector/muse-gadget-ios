import Foundation

/// What the home screen widget shows. The widget is a separate process with no connection to Muse,
/// so the app leaves this in storage both can read, and the widget shows the last thing it left.
struct MuseWidgetContent: Codable, Equatable {
    struct Card: Codable, Equatable {
        let title: String
        let body: String
        let endsAt: Date?
        let progress: Double?
    }

    var name: String?
    var card: Card?

    private static let appGroup = "group.com.exrector.MuseGadgetLegacy"
    private static let key = "widgetContent"

    /// Nil when the app was built without its app group, and then the widget simply stays empty.
    static var avatarURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("avatar.png")
    }

    static func load() -> MuseWidgetContent {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let content = try? JSONDecoder().decode(MuseWidgetContent.self, from: data) else {
            return MuseWidgetContent()
        }
        return content
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(data, forKey: Self.key)
    }
}
