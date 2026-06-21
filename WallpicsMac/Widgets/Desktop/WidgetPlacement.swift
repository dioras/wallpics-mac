import Foundation
import CoreGraphics

/// A widget placed on the desktop: which instance, where, at what size, and its interactive state.
/// Persisted to `WidgetPaths.placementsFile` so placements survive relaunch (the manager restores
/// them at launch).
struct DesktopWidgetPlacement: Codable, Equatable, Identifiable {
    var id: UUID                 // == WidgetInstance.id (one placement per instance)
    var originX: CGFloat         // bottom-left, in screen (AppKit) coordinates
    var originY: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// Interaction position to restore: themed reveal as 0/1, polaroid carousel index.
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

    // Custom decode so placements written by the previous (`isToggled: Bool`) build still load —
    // legacy `true` maps to step 1.
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

/// Disk persistence for desktop placements.
enum WidgetPlacementStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]; return e
    }()

    static func load() -> [DesktopWidgetPlacement] {
        guard let data = try? Data(contentsOf: WidgetPaths.placementsFile),
              let list = try? JSONDecoder().decode([DesktopWidgetPlacement].self, from: data) else {
            return []
        }
        return list
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
