import Foundation
import WidgetKit

/// Hands the widget what it shows. It asks for a redraw only when something changed, because iOS
/// limits how often a widget may be redrawn.
enum MuseWidgetPublisher {
    /// iOS refuses to draw a widget whose image is too large, and the limit is lower on old devices.
    static let avatarPixelSize = 512

    static func content(name: String?, card: MuseCard?) -> MuseWidgetContent {
        MuseWidgetContent(
            name: name,
            card: card.map {
                MuseWidgetContent.Card(
                    title: $0.title,
                    body: $0.body,
                    endsAt: $0.durationSeconds.map($0.shownAt.addingTimeInterval),
                    progress: $0.progress
                )
            }
        )
    }

    static func publish(name: String?, card: MuseCard?) {
        let new = content(name: name, card: card)
        guard new != MuseWidgetContent.load() else { return }
        new.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func publishAvatar(_ image: Data?) {
        DispatchQueue.global(qos: .utility).async {
            guard let url = MuseWidgetContent.avatarURL else { return }
            let small = image.flatMap { MuseImageScaler.scaled($0, maxPixelSize: avatarPixelSize)?.pngData() }
            guard small != (try? Data(contentsOf: url)) else { return }
            if let small {
                try? small.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
