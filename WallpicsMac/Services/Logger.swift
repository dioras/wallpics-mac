import Foundation
import os

enum Log {
    private static let subsystem = "app.wallpics.mac"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let app = Logger(subsystem: subsystem, category: "app")
}
