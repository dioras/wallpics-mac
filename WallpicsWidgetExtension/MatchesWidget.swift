import WidgetKit
import SwiftUI

struct MatchesEntry: TimelineEntry {
    let date: Date
    let games: [WCGame]
}

struct MatchesProvider: TimelineProvider {
    func placeholder(in context: Context) -> MatchesEntry {
        MatchesEntry(date: Date(), games: WidgetLiveAPI.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (MatchesEntry) -> Void) {
        if context.isPreview {
            completion(MatchesEntry(date: Date(), games: WidgetLiveAPI.sample))
            return
        }
        Task {
            let games = await WidgetLiveAPI.matches()
            completion(MatchesEntry(date: Date(), games: games))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MatchesEntry>) -> Void) {
        Task {
            let games = await WidgetLiveAPI.matches()
            let interval: TimeInterval = games.isEmpty ? 5 * 60 : 30 * 60
            let next = Date().addingTimeInterval(interval)
            completion(Timeline(entries: [MatchesEntry(date: Date(), games: games)], policy: .after(next)))
        }
    }
}

struct MatchesWidget: Widget {
    let kind = "WallpicsMatchesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MatchesProvider()) { entry in
            MatchesView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.06, green: 0.18, blue: 0.10),
                                            Color(red: 0.03, green: 0.09, blue: 0.05)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Today's Matches")
        .description("Live football scores on your desktop — updates on its own.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct MatchesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MatchesEntry

    private var rowCount: Int { family == .systemLarge ? 6 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "soccerball")
                    .font(.system(size: 13, weight: .bold))
                Text("TODAY'S MATCHES")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(0.5)
                Spacer()
            }
            .foregroundStyle(.white)

            let games = WidgetLiveAPI.relevant(entry.games, limit: rowCount)
            if games.isEmpty {
                Spacer()
                Text("No matches available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(games) { game in
                    row(game)
                    if game.id != games.last?.id {
                        Divider().overlay(.white.opacity(0.10))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ game: WCGame) -> some View {
        HStack(spacing: 8) {
            Text(game.home)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
            Text(score(game))
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .frame(width: 58)
            Text(game.away)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
    }

    private func score(_ game: WCGame) -> String {
        let started = game.kickoff.map { $0 <= Date() } ?? false
        if (game.finished || started), !game.homeScore.isEmpty, !game.awayScore.isEmpty {
            return "\(game.homeScore) - \(game.awayScore)"
        }
        if let kickoff = game.kickoff {
            return Self.timeFormatter.string(from: kickoff)
        }
        return "vs"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}
