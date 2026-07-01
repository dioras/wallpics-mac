import WidgetKit
import AppIntents
import SwiftUI

struct WallpicsWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let widget: SharedWidget?
    let cgImage: CGImage?
}

struct WallpicsWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = WallpicsWidgetEntry
    typealias Intent = SelectWidgetIntent

    func placeholder(in context: Context) -> WallpicsWidgetEntry {
        let widget = WidgetSharedStore.shared.allWidgets().first
        return makeEntry(for: widget, context: context)
    }

    func snapshot(for configuration: SelectWidgetIntent, in context: Context) async -> WallpicsWidgetEntry {
        let widget = resolveWidget(for: configuration)
        return makeEntry(for: widget, context: context)
    }

    func timeline(for configuration: SelectWidgetIntent, in context: Context) async -> Timeline<WallpicsWidgetEntry> {
        let widget = resolveWidget(for: configuration)
        if widget?.dateTime != nil {
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
            let start = calendar.date(from: comps) ?? Date()
            let entries = (0..<60).map { i -> WallpicsWidgetEntry in
                let date = calendar.date(byAdding: .minute, value: i, to: start) ?? start
                return WallpicsWidgetEntry(date: date, widget: widget, cgImage: nil)
            }
            return Timeline(entries: entries, policy: .atEnd)
        }
        let entry = makeEntry(for: widget, context: context)
        return Timeline(entries: [entry], policy: .never)
    }

    private func resolveWidget(for configuration: SelectWidgetIntent) -> SharedWidget? {
        let all = WidgetSharedStore.shared.allWidgets()
        if let id = configuration.selected?.id, let match = all.first(where: { $0.id == id }) {
            return match
        }
        return all.first(where: { WidgetSharedStore.shared.imageURL(for: $0) != nil }) ?? all.first
    }

    private func makeEntry(for widget: SharedWidget?, context: Context) -> WallpicsWidgetEntry {
        guard let widget else {
            return WallpicsWidgetEntry(date: Date(), widget: nil, cgImage: nil)
        }
        let maxPixelSize = pixelSize(for: context.family)
        let cg = WidgetSharedStore.shared.cgImage(for: widget, maxPixelSize: maxPixelSize)
        return WallpicsWidgetEntry(date: Date(), widget: widget, cgImage: cg)
    }

    private func pixelSize(for family: WidgetKit.WidgetFamily) -> Int {
        switch family {
        case .systemSmall:  return 600
        case .systemMedium: return 1000
        case .systemLarge:  return 1200
        default:            return 1000
        }
    }
}

struct WallpicsPhotoWidget: Widget {
    let kind = "WallpicsPhotoWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectWidgetIntent.self, provider: WallpicsWidgetProvider()) { entry in
            WallpicsWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WallpicsWidgetBackground(entry: entry)
                }
        }
        .configurationDisplayName("WallPics Widget")
        .description("Place it, then right-click → Edit Widget to pick from 100+ WallPics widgets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WallpicsWidgetBackground: View {
    let entry: WallpicsWidgetEntry

    var body: some View {
        if let dt = entry.widget?.dateTime {
            WidgetClockStyle.gradient(dt.backgroundHexes)
        } else if let cg = entry.cgImage {
            GeometryReader { proxy in
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        } else {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct WallpicsWidgetView: View {
    let entry: WallpicsWidgetEntry

    var body: some View {
        if let dt = entry.widget?.dateTime {
            ClockFace(state: dt, date: entry.date)
        } else if entry.cgImage != nil {
            Color.clear
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.badge.plus")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text("Right-click → Edit Widget")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("then choose a WallPics widget")
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
