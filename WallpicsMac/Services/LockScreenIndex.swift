import Foundation

enum LockScreenIndex {
    static let aerialProvider = "com.apple.wallpaper.choice.aerials"

    static func aerialChoice(_ id: String) throws -> [String: Any] {
        let blob = try PropertyListSerialization.data(fromPropertyList: ["assetID": id], format: .binary, options: 0)
        return ["Provider": aerialProvider, "Configuration": blob, "Files": [String]()]
    }

    @discardableResult
    static func applyAerialChoice(in node: Any, choice: [String: Any]) -> Int {
        var matched = 0
        if let dict = node as? NSMutableDictionary {
            for key in ["Desktop", "Idle"] {
                if let container = dict[key] as? NSMutableDictionary,
                   let content = container["Content"] as? NSMutableDictionary,
                   content["Choices"] != nil {
                    content["Choices"] = [choice]
                    content.removeObject(forKey: "EncodedOptionValues")
                    matched += 1
                }
            }
            for value in dict.allValues { matched += applyAerialChoice(in: value, choice: choice) }
        } else if let array = node as? NSArray {
            for value in array { matched += applyAerialChoice(in: value, choice: choice) }
        }
        return matched
    }

    static func collectAerialIDs(in node: Any, section: String) -> [String] {
        var out: [String] = []
        forEachChoiceList(in: node, section: section) { choices in
            out += choices.compactMap(aerialID(of:))
        }
        return out
    }

    static func desktopPoints(to id: String, in root: Any) -> Bool {
        var sections = 0
        var mismatches = 0
        forEachChoiceList(in: root, section: "Desktop") { choices in
            sections += 1
            let ids = choices.compactMap(aerialID(of:))
            if ids.count != choices.count || ids != [id] { mismatches += 1 }
        }
        return sections > 0 && mismatches == 0
    }

    static func aerialID(of choice: [String: Any]) -> String? {
        guard (choice["Provider"] as? String) == aerialProvider,
              let blob = choice["Configuration"] as? Data,
              let obj = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
              let cfg = obj as? [String: Any],
              let id = cfg["assetID"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    private static func forEachChoiceList(in node: Any, section: String, _ visit: ([[String: Any]]) -> Void) {
        if let dict = node as? [String: Any] {
            if let sec = dict[section] as? [String: Any],
               let content = sec["Content"] as? [String: Any],
               let choices = content["Choices"] as? [[String: Any]] {
                visit(choices)
            }
            for value in dict.values { forEachChoiceList(in: value, section: section, visit) }
        } else if let array = node as? [Any] {
            for item in array { forEachChoiceList(in: item, section: section, visit) }
        }
    }
}
