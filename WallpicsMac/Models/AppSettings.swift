import Foundation

struct AppSettings: Codable, Equatable {
    var cacheRecentWallpapers: Bool
    var playOnBatteryPower: Bool
    var pauseOnLowPowerMode: Bool
    var respectSystemAppearance: Bool
    /// nil = follow the system language.
    var languageCode: String?

    static let `default` = AppSettings(
        cacheRecentWallpapers: true,
        playOnBatteryPower: true,
        pauseOnLowPowerMode: true,
        respectSystemAppearance: true,
        languageCode: nil
    )

    enum CodingKeys: String, CodingKey {
        case cacheRecentWallpapers, playOnBatteryPower, pauseOnLowPowerMode, respectSystemAppearance, languageCode
    }

    init(cacheRecentWallpapers: Bool, playOnBatteryPower: Bool, pauseOnLowPowerMode: Bool, respectSystemAppearance: Bool, languageCode: String?) {
        self.cacheRecentWallpapers = cacheRecentWallpapers
        self.playOnBatteryPower = playOnBatteryPower
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.respectSystemAppearance = respectSystemAppearance
        self.languageCode = languageCode
    }

    // Tolerant decode so an older settings.json (without languageCode) still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cacheRecentWallpapers = (try? c.decode(Bool.self, forKey: .cacheRecentWallpapers)) ?? true
        playOnBatteryPower = (try? c.decode(Bool.self, forKey: .playOnBatteryPower)) ?? true
        pauseOnLowPowerMode = (try? c.decode(Bool.self, forKey: .pauseOnLowPowerMode)) ?? true
        respectSystemAppearance = (try? c.decode(Bool.self, forKey: .respectSystemAppearance)) ?? true
        languageCode = try? c.decodeIfPresent(String.self, forKey: .languageCode)
    }

    static var fileURL: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = appSupport.appendingPathComponent("WallpicsMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        guard let url = AppSettings.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
