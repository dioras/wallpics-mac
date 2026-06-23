import Foundation
import CoreGraphics

struct DesktopWidgetPlacement: Codable, Equatable, Identifiable {
    var id: UUID
    var originX: CGFloat
    var originY: CGFloat
    var width: CGFloat
    var height: CGFloat
    var step: Int

    var frame: CGRect {
        get { CGRect(x: originX, y: originY, width: width, height: height) }
        set {
            originX = newValue.origin.x; originY = newValue.origin.y
            width = newValue.size.width; height = newValue.size.height
        }
    }

    init(id: UUID, frame: CGRect, step: Int = 0) {
        self.id = id
        self.originX = frame.origin.x
        self.originY = frame.origin.y
        self.width = frame.size.width
        self.height = frame.size.height
        self.step = step
    }

    private enum CodingKeys: String, CodingKey {
        case id, originX, originY, width, height, step, isToggled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originX = try c.decode(CGFloat.self, forKey: .originX)
        originY = try c.decode(CGFloat.self, forKey: .originY)
        width = try c.decode(CGFloat.self, forKey: .width)
        height = try c.decode(CGFloat.self, forKey: .height)
        if let s = try c.decodeIfPresent(Int.self, forKey: .step) {
            step = s
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .isToggled) {
            step = legacy ? 1 : 0
        } else {
            step = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(originX, forKey: .originX)
        try c.encode(originY, forKey: .originY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(step, forKey: .step)
    }
}

enum WidgetPlacementStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]; return e
    }()

    static func load() -> [DesktopWidgetPlacement] {
        let url = WidgetPaths.placementsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([DesktopWidgetPlacement].self, from: data)
        } catch {
            Log.app.error("Placements load failed; backing up corrupt file: \(error.localizedDescription, privacy: .public)")
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    static func save(_ placements: [DesktopWidgetPlacement]) {
        do {
            let data = try encoder.encode(placements)
            try data.write(to: WidgetPaths.placementsFile, options: .atomic)
        } catch {
            Log.app.error("Desktop widget placements save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
