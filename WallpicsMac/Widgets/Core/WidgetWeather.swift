import Foundation
import Observation
import os

struct WidgetWeatherReading: Codable, Equatable, Sendable {
    var temperature: Double
    var high: Double?
    var low: Double?
    var code: Int
    var isDay: Bool
    var fetchedAt: Date
}

struct WidgetWeatherPlace: Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
}

@MainActor
@Observable
final class WidgetWeather {
    static let shared = WidgetWeather()

    private(set) var readings: [String: WidgetWeatherReading] = [:]
    private(set) var failedKeys: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []

    private static let freshness: TimeInterval = 30 * 60

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static var cacheFile: URL { WidgetPaths.root.appendingPathComponent("weather.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheFile),
           let cached = try? JSONDecoder().decode([String: WidgetWeatherReading].self, from: data) {
            readings = cached
        }
    }

    static func key(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }

    func reading(latitude: Double, longitude: Double) -> WidgetWeatherReading? {
        readings[Self.key(latitude: latitude, longitude: longitude)]
    }

    func isFailing(latitude: Double, longitude: Double) -> Bool {
        failedKeys.contains(Self.key(latitude: latitude, longitude: longitude))
    }

    func refreshIfNeeded(latitude: Double, longitude: Double) async {
        let key = Self.key(latitude: latitude, longitude: longitude)
        if let cached = readings[key], Date().timeIntervalSince(cached.fetchedAt) < Self.freshness,
           !failedKeys.contains(key) {
            return
        }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            readings[key] = try await fetch(latitude: latitude, longitude: longitude)
            failedKeys.remove(key)
            persist()
        } catch {
            failedKeys.insert(key)
            Log.app.error("Weather fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func search(_ query: String) async throws -> WidgetWeatherPlace? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await session.data(from: url)
        try Self.ensureOK(response)
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
        }
        struct Response: Decodable { let results: [Result]? }
        guard let first = try JSONDecoder().decode(Response.self, from: data).results?.first else { return nil }
        let name = [first.name, first.country].compactMap { $0 }.joined(separator: ", ")
        return WidgetWeatherPlace(name: name, latitude: first.latitude, longitude: first.longitude)
    }

    private func fetch(latitude: Double, longitude: Double) async throws -> WidgetWeatherReading {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        try Self.ensureOK(response)
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int?
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
        }
        struct Response: Decodable {
            let current: Current
            let daily: Daily?
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        return WidgetWeatherReading(temperature: parsed.current.temperature_2m,
                                    high: parsed.daily?.temperature_2m_max?.first ?? nil,
                                    low: parsed.daily?.temperature_2m_min?.first ?? nil,
                                    code: parsed.current.weather_code,
                                    isDay: (parsed.current.is_day ?? 1) == 1,
                                    fetchedAt: Date())
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(readings) else { return }
        try? data.write(to: Self.cacheFile, options: .atomic)
    }

    private static func ensureOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0:             return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:          return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:             return "cloud.fill"
        case 45, 48:        return "cloud.fog.fill"
        case 51...57:       return "cloud.drizzle.fill"
        case 61...67:       return "cloud.rain.fill"
        case 80...82:       return "cloud.heavyrain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99:       return "cloud.bolt.rain.fill"
        default:            return "cloud.fill"
        }
    }

    static func label(code: Int) -> String {
        switch code {
        case 0:             return String(localized: "Clear")
        case 1, 2:          return String(localized: "Partly cloudy")
        case 3:             return String(localized: "Cloudy")
        case 45, 48:        return String(localized: "Fog")
        case 51...57:       return String(localized: "Drizzle")
        case 61...67, 80...82: return String(localized: "Rain")
        case 71...77, 85, 86: return String(localized: "Snow")
        case 95...99:       return String(localized: "Thunderstorm")
        default:            return String(localized: "Cloudy")
        }
    }
}
