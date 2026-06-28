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
        let entry = makeEntry(for: widget, context: context)
        return Timeline(entries: [entry], policy: .never)
    }

    private func resolveWidget(for configuration: SelectWidgetIntent) -> SharedWidget? {
        if let id = configuration.selected?.id, let match = WidgetSharedStore.shared.widget(id: id) {
            return match
        }
        return WidgetSharedStore.shared.allWidgets().first
    }

    private func makeEntry(for widget: SharedWidget?, context: Context) -> WallpicsWidgetEntry {
        guard let widget else {
            return WallpicsWidgetEntry(date: Date(), widget: nil, cgImage: nil)
        }
        let maxPixelSize = pixelSize(for: context.family)
        let cg = WidgetSharedStore.shared.cgImage(for: widget, maxPixelSize: maxPixelSize)
        return WallpicsWidgetEntry(date: Date(), widget: widget, cgImage: cg)
    }

    private func pixelSize(for family: WidgetFamily) -> Int {
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
        .configurationDisplayName("WallPics Photo")
        .description("Show one of your WallPics widgets on your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WallpicsWidgetBackground: View {
    let entry: WallpicsWidgetEntry

    var body: some View {
        if let cg = entry.cgImage {
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
        if entry.cgImage != nil {
            Color.clear
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.artframe")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text("Open WallPics to pick a widget")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
