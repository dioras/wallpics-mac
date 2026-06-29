import Foundation
import CryptoKit

struct WCGame: Decodable, Identifiable, Sendable {
    let id: String
    let home: String
    let away: String
    let homeScore: String
    let awayScore: String
    let dateString: String
    let finished: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case home = "home_team_name_en"
        case away = "away_team_name_en"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case dateString = "local_date"
        case finished
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        home = (try? c.decode(String.self, forKey: .home)) ?? "—"
        away = (try? c.decode(String.self, forKey: .away)) ?? "—"
        homeScore = (try? c.decode(String.self, forKey: .homeScore)) ?? ""
        awayScore = (try? c.decode(String.self, forKey: .awayScore)) ?? ""
        dateString = (try? c.decode(String.self, forKey: .dateString)) ?? ""
        let raw = (try? c.decode(String.self, forKey: .finished)) ?? "FALSE"
        finished = raw.uppercased() == "TRUE"
    }

    init(id: String, home: String, away: String, homeScore: String, awayScore: String, dateString: String, finished: Bool) {
        self.id = id
        self.home = home
        self.away = away
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.dateString = dateString
        self.finished = finished
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm"
        return f
    }()

    var kickoff: Date? { Self.parser.date(from: dateString) }
}

private struct WCResponse: Decodable {
    let games: [WCGame]
}

enum WidgetLiveAPI {
    private static let base = "https://backend.wallpics.app"
    private static let salt = "wall"

    static func matches() async -> [WCGame] {
        guard let url = URL(string: "\(base)/api/world-cup/games") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        let ts = String(Int(Date().timeIntervalSince1970))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacOS", forHTTPHeaderField: "X-App-Platform")
        request.setValue(ts, forHTTPHeaderField: "x-auth")
        request.setValue(md5(ts + salt), forHTTPHeaderField: "x-token")
        request.setValue("1", forHTTPHeaderField: "x-get-guest-id")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(WCResponse.self, from: data) else {
            return []
        }
        return decoded.games
    }

    static func relevant(_ games: [WCGame], limit: Int, now: Date = Date()) -> [WCGame] {
        let named = games.filter { $0.home != "—" && $0.away != "—" && !$0.home.isEmpty && !$0.away.isEmpty }
        func started(_ g: WCGame) -> Bool { g.kickoff.map { $0 <= now } ?? false }
        let live = named.filter { !$0.finished && started($0) }
        let rest = named.filter { $0.finished || !started($0) }
            .sorted {
                abs(($0.kickoff ?? .distantPast).timeIntervalSince(now)) <
                abs(($1.kickoff ?? .distantPast).timeIntervalSince(now))
            }
        return Array((live + rest).prefix(limit))
    }

    static let sample: [WCGame] = [
        WCGame(id: "s1", home: "Brazil", away: "Norway", homeScore: "2", awayScore: "1", dateString: "", finished: true),
        WCGame(id: "s2", home: "France", away: "Japan", homeScore: "3", awayScore: "0", dateString: "", finished: true),
        WCGame(id: "s3", home: "Spain", away: "Morocco", homeScore: "1", awayScore: "1", dateString: "", finished: true),
        WCGame(id: "s4", home: "Argentina", away: "Mexico", homeScore: "2", awayScore: "0", dateString: "", finished: true),
        WCGame(id: "s5", home: "Germany", away: "Portugal", homeScore: "0", awayScore: "2", dateString: "", finished: true),
        WCGame(id: "s6", home: "England", away: "Croatia", homeScore: "1", awayScore: "0", dateString: "", finished: true)
    ]

    private static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
