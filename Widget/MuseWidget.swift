import SwiftUI
import UIKit
import WidgetKit

struct MuseWidgetEntry: TimelineEntry {
    let date: Date
    let content: MuseWidgetContent
    let avatar: UIImage?
}

struct MuseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MuseWidgetEntry {
        MuseWidgetEntry(date: Date(), content: MuseWidgetContent(), avatar: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MuseWidgetEntry) -> Void) {
        completion(current(at: Date()))
    }

    /// The app asks for a redraw when something changes. The only change of its own is a timer ending.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MuseWidgetEntry>) -> Void) {
        let now = current(at: Date())
        var entries = [now]
        if let end = now.content.card?.endsAt, end > now.date {
            entries.append(MuseWidgetEntry(date: end, content: now.content, avatar: now.avatar))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func current(at date: Date) -> MuseWidgetEntry {
        MuseWidgetEntry(
            date: date,
            content: MuseWidgetContent.load(),
            avatar: MuseWidgetContent.avatarURL.flatMap { UIImage(contentsOfFile: $0.path) }
        )
    }
}

private struct MuseWidgetAvatar: View {
    let image: UIImage?
    var fills = false

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: fills ? .fill : .fit)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0, green: 0.65, blue: 0.75), Color(red: 0, green: 0.5, blue: 0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(.white)
            }
            .aspectRatio(fills ? nil : 1, contentMode: .fit)
        }
    }
}

private struct MuseWidgetCardView: View {
    let card: MuseWidgetContent.Card
    let date: Date
    var titleFont = Font.headline
    var timerFont = Font.title.weight(.semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: card.title)
                .font(titleFont)
                .lineLimit(2)
            if let end = card.endsAt {
                if end > date {
                    Text(end, style: .timer)
                        .font(timerFont.monospacedDigit())
                } else {
                    Text(verbatim: "0:00")
                        .font(timerFont.monospacedDigit())
                }
            } else if let progress = card.progress {
                ProgressView(value: min(max(progress, 0), 1))
            }
            if !card.body.isEmpty {
                Text(verbatim: card.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(4)
            }
        }
    }
}

struct MuseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MuseWidgetEntry

    private var name: String { entry.content.name ?? "Muse" }

    var body: some View {
        if #available(iOS 16.0, *), family == .accessoryCircular {
            lockScreenCircle
        } else if #available(iOS 16.0, *), family == .accessoryRectangular {
            lockScreenRectangle
        } else if #available(iOS 16.0, *), family == .accessoryInline {
            lockScreenLine
        } else {
            switch family {
            case .systemSmall:
                small
            case .systemMedium:
                sideBySide(padding: 12, nameFont: .headline)
            case .systemLarge:
                large
            default:
                sideBySide(padding: 20, nameFont: .title2.weight(.semibold))
            }
        }
    }

    private var runningTimerEnd: Date? {
        guard let end = entry.content.card?.endsAt, end > entry.date else { return nil }
        return end
    }

    @available(iOS 16.0, *)
    private var lockScreenCircle: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let avatar = entry.avatar {
                Image(uiImage: avatar)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "sparkles")
            }
        }
        .clipShape(Circle())
    }

    /// A card can be private, so it stays hidden while the device is locked if the person asks for that.
    private var lockScreenRectangle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: name)
                .font(.headline)
                .lineLimit(1)
            Group {
                if let end = runningTimerEnd {
                    Text(end, style: .timer)
                        .monospacedDigit()
                } else if let title = entry.content.card?.title {
                    Text(verbatim: title)
                        .lineLimit(2)
                }
            }
            .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var lockScreenLine: some View {
        if let end = runningTimerEnd {
            Text(end, style: .timer)
        } else {
            Text(verbatim: name)
        }
    }

    private var small: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                MuseWidgetAvatar(image: entry.avatar, fills: true)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let end = entry.content.card?.endsAt, end > entry.date {
                    Text(end, style: .timer)
                        .font(.caption.monospacedDigit())
                } else if let title = entry.content.card?.title {
                    Text(verbatim: title)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .padding(10)
        }
    }

    private func sideBySide(padding: CGFloat, nameFont: Font) -> some View {
        HStack(spacing: padding) {
            MuseWidgetAvatar(image: entry.avatar)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: name)
                    .font(nameFont)
                    .lineLimit(1)
                if let card = entry.content.card {
                    MuseWidgetCardView(card: card, date: entry.date, titleFont: .subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(padding)
    }

    private var large: some View {
        VStack(spacing: 10) {
            MuseWidgetAvatar(image: entry.avatar)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let card = entry.content.card {
                    MuseWidgetCardView(card: card, date: entry.date)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}

private struct MuseWidgetBackground: ViewModifier {
    @Environment(\.widgetFamily) private var family

    private var onLockScreen: Bool {
        guard #available(iOS 16.0, *) else { return false }
        return [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
    }

    private var color: Color {
        onLockScreen ? .clear : Color(UIColor.secondarySystemBackground)
    }

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(for: .widget) { color }
        } else {
            content.background(color)
        }
    }
}

struct MuseAvatarWidget: Widget {
    /// Everything iOS has for a phone or tablet. It offers only what the device can show.
    private var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 16.0, *) {
            families += [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
        return families
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MuseAvatarWidget", provider: MuseWidgetProvider()) { entry in
            MuseWidgetView(entry: entry).modifier(MuseWidgetBackground())
        }
        .configurationDisplayName(Text(verbatim: "Pal Again"))
        .description(Text("Аватар, имя и карточка Muse."))
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
}

@main
struct MuseWidgetBundle: WidgetBundle {
    var body: some Widget {
        MuseAvatarWidget()
    }
}
